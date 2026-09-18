# STP 修复记录 — 2026-09-17（stpmgrd/stpd IPC 错位 + STP 初始化非幂等）

作者：虾人（受 Mike 指派）  审核：待 Mike review
分支：sc-202505（sonic_orig → GitHub mikeDing1107/sonic-buildimage）
编译树：编译 VM `/home/ubuntu/0910/sonic-buildimage`

---

## 1. 背景与根因

板子（KaiTian，marvell-prestera arm64）STP 一直不工作：CONFIG_DB 里 `STP|GLOBAL mode=pvst`、
`STP_VLAN|Vlan53/Vlan149`、`STP_PORT|Ethernet26/27/28` 都配了，但 stpd 侧
`stpctl global` 显示 `enable_mask` 空、`max port = 0`、`max_instances = 256`（CONFIG_DB 明明写的是 2）。

查下来是**两个独立问题**：

### 1.1 stpmgrd(swss) 与 stpd(sonic-stp) 的 IPC 报文布局不一致（主因）

两个仓库各存一份 STP IPC 结构定义：

| 定义位置 | 仓库 / pin |
|---|---|
| `include/stp_ipc.h` | sonic-net/**sonic-stp** @ `0a74023f`（2025-05-08） |
| `cfgmgr/stpmgr.h` | sonic-net/**sonic-swss** @ `278ff13e`（2025-12-18，202505 分支） |

`stpmgr.h` 里自己写着 `// Enumerations must match stp_ipc.h`、`// Must match the version in stp_ipc.h exactly`，
但实际错位两处：

| 结构体 | sonic-stp（stpd/stpctl 侧） | sonic-swss（stpmgrd 侧，修复前） |
|---|---|---|
| `STP_IPC_MSG` | `{msg_type, msg_len, **proto_mode**, data[0]}` → size 12，data@12 | 少 `proto_mode` → size 8，data@8 |
| `STP_PORT_CONFIG_MSG` | `… uplink_fast, **int edge**, padding, path_cost@32, vlan_list@44` → size 44 | 少 `int edge` → path_cost@28, vlan_list@44→**40**，size 40 |

后果：stpmgrd 发的**每一条** IPC 消息，stpd 都按 12 字节头解析，payload 整体错位 4 字节：
- `STP_BRIDGE_CONFIG`：stpd 读到的 `opcode` 其实是 `rootguard_timeout` 的低字节（默认 30）→ 既不是
  `STP_SET_COMMAND(1)` 也不是 `STP_DEL_COMMAND(0)` → 配置被静默忽略，STP 永远 enable 不起来；
- `STP_INIT_READY`：`max_stp_instances`（swss 侧放在 payload+2，共 4 字节）被 stpd 从 payload+6 读 →
  **读到消息以外**的内存 → 板子上 stpd 报 `max_instances = 256`（swss 只可能发 STATE_DB 值或默认 255）
  —— 这就是错位的直接实测证据；
- `STP_PORT_CONFIG`：`path_cost/priority/count/vlan_list` 全部错 4 字节。

上游方向也印证是 **swss 侧落后**：sonic-swss `master` / `202511` 都已经有 `proto_mode` 和 MST 枚举，
只有 `202505` 分支没有（我们是 202505）；而 sonic-stp 的 `stpctl` 与 `stpd` 共用同一份
`stp_ipc.h`（改 stp 等于让 stpctl 一起改并丢掉 MST）。上游历史上也一直是 swss 追 stp
（swss #3440 对齐结构、#3752「stpd crashes due to wrong no. of stp instance passed from stpmgrd」、#3606 [MSTP] Swss Support）。

### 1.2 stpd 的 `STP_INIT_READY` 处理不是幂等的（次因，会让 STP 彻底死掉）

`stp/stp_mgr.c: stpmgr_process_ipc_msg()` 收到 `STP_INIT_READY` 就调
`stp_intf_event_mgr_init()`（`stp/stp_intf.c`）：该函数**开头就把 `g_max_stp_port = 0`**，
再走 netlink 端口枚举把端口 DB 重建成；而 `stpmgr_process_ipc_msg()` 有门禁：

```c
if (msg->msg_type != STP_INIT_READY && msg->msg_type != STP_STPCTL_MSG)
    if (g_max_stp_port == 0) { /* 丢包 */ return; }
```

stpmgrd 每次（重）启动都会重发一条 `STP_INIT_READY`（容器内 supervisor 日志可见 stpmgrd 重启过数次），
第二次进来如果端口枚举失败/为空，`g_max_stp_port` 就永久为 0 → **之后所有 STP 配置消息全被丢弃**。
板子上 `max port = 0` 但 `fastspan_mask` 又打印了 1..63（位图是按当时端口数分配过的）——正是"跑过又被清 0"的痕迹。

---

## 2. 改动清单（6 个补丁）

全部按 `patches/sc_XXXX_*.patch` + `series_sercomm-prestera_arm64` 的方式纳入构建，`git am` 逐条应用。

| 补丁 | 目标 submodule | 内容 |
|---|---|---|
| `sc_0010_add_stp_bounds_check.patch` | src/sonic-stp | `msgtype_str[]` 补齐 4 个 MST 项（9→13，与 `stp_ipc.h` 枚举对齐）；两处下标越界读加边界判断；`stp_data.c` 的 `stp_index` 越界加范围检查；`stp_util.c` `strcpy→strncpy` |
| `sc_0011_fix_stp_netlink_oob.patch` | src/sonic-stp | `stp_netlink_request()` 用 `struct {nlmsghdr; rtgenmsg;} req`，修 16 字节栈缓冲按 20 字节越界读 |
| `sc_0012_fix_stp_pkt_buf.patch` | src/sonic-stp | `stp_pkt_dump()` 的 `pkt_str[256]→[1024]`（sprintf 最多写 576 字节） |
| `sc_0013_stp_no_abort_on_zero_instances.patch` | src/sonic-stp | `stpmgr_init()` 收到 0 个实例时不再 `sys_assert(0)` 自杀，改为告警+回退（回退值 256 保留为"哨兵"：日志/`stpctl global` 再出现 256 就说明 fallback 被触发） |
| **`sc_0020_stp_ignore_duplicate_init_ready.patch`** | src/sonic-stp | **新增**：`INIT_READY` 幂等化——`g_stpd_port_init_done` 已置位时忽略重复 `INIT_READY`（不再重置 `g_max_stp_port`、不再重建端口 DB），`stp_intf_event_mgr_init()` 自身也加同样的保护 |
| **`sc_0021_align_stpmgrd_stp_ipc_layout.patch`** | src/sonic-swss | **新增（主修复）**：`STP_IPC_MSG` 加回 `L2_PROTO_MODE proto_mode`；`L2_PROTO_MODE` 补 `L2_MSTP`；`STP_MSG_TYPE` 补 4 个 MST 值（插在 `STP_STPCTL_MSG` 与 `STP_MAX_MSG` 之间，**已有枚举值 0..7 不变**）；`STP_CTL_TYPE` 补 `STP_CTL_DUMP_MST(_PORT)`；`STP_PORT_CONFIG_MSG` 补 `int edge`；`stpmgr.cpp: sendMsgStpd()` 填 `tx_msg->proto_mode = l2ProtoEnabled` |

注意 `sc_0010/0011` 之前在 0811 树里已有（内容等价，本次重新按 pin 生成、格式规范化为 `git format-patch`），
`sc_0012/0013` 之前只是手改 + 非标准 patch，本次一并规范化。

## 3. 布局对齐验证（编译前静态核对）

用同一份 C 代码对两个头文件求 `sizeof` / `offsetof`（`/tmp/work/layout/check2.c`）：

```
variant     struct                      size     data path_cost vlan_list
stp_pin     STP_IPC_MSG                   12       12        -1        -1
swss_pin    STP_IPC_MSG                    8        8        -1        -1   ← 错位
swss_fixed  STP_IPC_MSG                   12       12        -1        -1   ← 对齐 ✓
stp_pin     STP_PORT_CONFIG_MSG           44       -1        32        44
swss_pin    STP_PORT_CONFIG_MSG           40       -1        28        40   ← 错位
swss_fixed  STP_PORT_CONFIG_MSG           44       -1        32        44   ← 对齐 ✓
（其余结构体修复前后两侧本来就一致）
```

补丁已用 `git am` 在 pin 干净树上逐条验证可应用（stp: sc_0009 → sc_0010 → sc_0011 → sc_0012 →
sc_0013 → sc_0020；swss: sc_0021）。

## 4. 编译与板子验证

（下面由本次执行结果填写）

- [ ] stp deb 重编：`target/debs/bookworm/stp_1.0.0_arm64.deb`
- [ ] swss deb 重编：`target/debs/bookworm/swss_1.0.0_arm64.deb`
- [ ] 板子替换后 `stpctl global`：`max_instances` 不再是 256（应为 255/配置值）、`max port` 非 0
- [ ] `config spanning-tree enable pvst` 后 `enable_mask` 有端口、`show spanning-tree` 有输出
- [ ] APPL_DB `STP_VLAN_TABLE` / `STP_PORT_STATE_TABLE` 有数据

## 5. 复现 / 复核方式

```bash
# 源码树（构建服务器 172.21.53.200）
/home2/mike_ding/work/Switch/project/kaitian/sonic_orig/latest/sonic-buildimage/patches/sc_00{10,11,12,13,20,21}_*.patch
/home2/mike_ding/work/Switch/project/kaitian/sonic_orig/latest/sonic-buildimage/series_sercomm-prestera_arm64

# 干净复现验证（任意机器）
git clone https://github.com/sonic-net/sonic-stp && git checkout 0a74023f3a1bac67e61e2568687aaba78d4a78fc
git am <patches>/sc_0009_*.patch <patches>/sc_001{0,1,2,3}_*.patch <patches>/sc_0020_*.patch
git clone https://github.com/sonic-net/sonic-swss && git checkout 278ff13eff55bde611a9df0f9170c96c5aecc478
git am <patches>/sc_0021_*.patch
```

## 6. 遗留 / 待确认

1. `STP_PORT_CONFIG_MSG.edge` 目前 swss 侧只是把字段补上（memset 0），未接 CONFIG_DB 的来源
   （PVST 用不到；MSTP 需要时再补，上游 master 也是近期才加 `loop_guard/edge_port/link_type`）。
2. 上游 swss master 与 stp master 在 `STP_PORT_CONFIG_MSG` 上**仍不同步**（master 用
   `uint8_t edge/x + LinkType`，两边字段还不一样），将来升级 pin 时要重新核对一遍该结构。
3. `g_max_stp_port` 变成 0 的另一条路径（首个 INIT_READY 就枚举不到端口）没有根治：
   只做了"不再被第二次 INIT_READY 清零"。若首次就失败，stpd 仍会一直丢配置（但会打
   `max port invalid ignore msg type` 日志）。
4. wc 建议：后续把 stpmgrd/stpd 的 IPC 结构收敛成**单一头文件**（或加编译期
   `static_assert(sizeof(...)==N)` 断言），避免再次错位。

---

## 7. 板子验证结果（2026-09-17 16:00~16:20 CST，sc_0021 版本）

**部署**：VM deb → `scp` 构建服务器 → 本机 → `ftp.sh put` 192.168.10.90 → 板子 `curl -O` →
`docker cp` 到 `stp:/root/`（**容器的 `/tmp` 拷进去看不到，必须用 `/root/`**）→ `dpkg -i` → `docker restart stp`。
md5 两端一致（swss `2168d9cf…`、stp `d5334c3a…`）。

| 项 | 替换前 | 替换后 |
|---|---|---|
| `show spanning-tree` | 无输出 / 不工作 | **正常**：PVST、VLAN53→instance 1、VLAN149→instance 0 |
| `stpctl global` `enable_mask` | 空 | `26 27 28` |
| `stpctl global` `max port` | 0 | **64** |
| `stpctl global` `active_instances` | 0 | **2** |
| APPL_DB `STP_VLAN_INSTANCE_TABLE` | — | `Vlan53{stp_instance=1}`、`Vlan149{stp_instance=0}` |
| `stpctl global` `max_instances` | 256（错位读出的垃圾） | 21321（**仍是垃圾** → 见 §8） |

端口显示 DISABLED 是因为 Ethernet26/27/28 `Oper=down`（没插线），不是缺陷。
容器内没有 `strings`；用 `grep -a -c 'fall back to' /usr/bin/stpd`、`grep -a -c 'max stp instance' /usr/bin/stpmgrd` 确认新二进制已装。

## 8. 第二个 bug：stpmgrd 的 max_stp_instances 未初始化（sc_0022）

- `StpMgr::max_stp_instances`（`cfgmgr/stpmgr.h:224`，`uint16_t`）**构造函数未初始化**；
  `getStpMaxInstances()`（`stpmgr.cpp:1079`）只从 **STATE_DB `STP|GLOBAL.max_stp_inst`** 取值，
  而该字段在本 build **无人写入**：orchagent `StpOrch` 仅有 `updateMaxStpInstance()` 的声明
  （`orchagent/stporch.h:26`），既无实现也无调用，`m_stpTable` 建了从不 `.set()`。
- 后果：`while(max_delay)` 空转 60 秒 → 成员保持未初始化 → `STP_INIT_READY.max_stp_instances`
  发垃圾值（实测 `stpd max_instances = 21321`）；同时 stpmgrd 启动被拖 60s。
- **sc_0022** `sc_0022_stpmgrd_max_stp_instances_fallback.patch`（sonic-swss，commit `5fb28b96`）：
  构造函数 `max_stp_instances = 0;`；`getStpMaxInstances()` 在 STATE_DB 为空时回退 CONFIG_DB
  `STP|GLOBAL.max_stp_instances`，再回退 `STP_DEFAULT_MAX_INSTANCES`。
- 预期结果：`stpctl global` 的 `max_instances` 变为 **2**（CONFIG_DB 配置值）。
- 上游建议：补上 `StpOrch::updateMaxStpInstance()`（orchagent 写 STATE_DB）才是正解；
  本补丁是 swss 侧的最小可用回退。

## 9. sc_0022 板上验证通过（2026-09-17 19:05 CST）

- 编译：18:41 完成（`SWSS_DEB_RC=0` / `BUILD_ALL_OK`），deb `2872508 B`，md5 `68b5cec58b3415033aa2522c077764da`
- 部署流程同上；重启 stp 容器后 ~2 分钟取值

| 字段 | sc_0021（旧） | sc_0022（新） |
|---|---|---|
| `max_instances` | 21321 | **2** |
| `active_instances` | 2 | 2 |
| `enable_mask` | 26 27 28 | 26 27 28 |
| `max port` | 64 | 64 |
| `show spanning-tree` | 正常 | 正常 |

遗留（非阻塞）：`getStpMaxInstances()` 的 60×sleep(1) 空转仍在（sc_0022 在循环之后才回退到
CONFIG_DB），stpmgrd 启动仍白等 60s。正解是补上 `StpOrch::updateMaxStpInstance()` 写 STATE_DB；
若要快启动，可把 STATE_DB 查询改为单次尝试。

**STP IPC 修复任务收尾**：sc_0009 ~ sc_0022 全部在板子上生效并验证完毕。

#!/usr/bin/env python3
import time
import json
import os
from sonic_py_common import daemon_base

CONFIG_FILE = "/tmp/cpu_monitor_config.json"
LOG_FILE = "/var/log/cpu_monitor.log"


class CPUCollector(daemon_base.DaemonBase):
    def __init__(self):
        super(CPUCollector, self).__init__("cpu_monitor_collector")
        self.last_cpu_times = None
        self.cached_config = {"enable": False, "interval": 10}
        self.last_read_time = 0

    def read_config(self):
        current_time = time.time()
        if current_time - self.last_read_time > 5:
            try:
                if os.path.exists(CONFIG_FILE):
                    with open(CONFIG_FILE, "r") as f:
                        self.cached_config = json.load(f)
                self.last_read_time = current_time
            except Exception as e:
                self.log_error(f"Failed to read config file: {e}")
        return self.cached_config

    def read_cpu_info(self):
        try:
            with open("/proc/stat", "r") as f:
                line = f.readline()
            cpu_vals = list(map(int, line.split()[1:]))

            current_idle = (
                cpu_vals[3] + cpu_vals[4] if len(cpu_vals) > 4 else cpu_vals[3]
            )
            current_total = sum(cpu_vals)

            if self.last_cpu_times is None:
                self.last_cpu_times = (current_total, current_idle)
                time.sleep(1)
                return 0.0

            last_total, last_idle = self.last_cpu_times
            total_diff = current_total - last_total
            idle_diff = current_idle - last_idle
            self.last_cpu_times = (current_total, current_idle)

            if total_diff == 0:
                return 0.0

            return round((total_diff - idle_diff) / total_diff * 100, 2)
        except Exception as e:
            self.log_error(f"Failed to read /proc/stat: {e}")
            return 0.0

    def run(self):
        self.log_info("CPU Collector started...")

        while True:
            config = self.read_config()
            enable = config.get("enable", False)
            interval = config.get("interval", 10)

            if enable:
                cpu_usage = self.read_cpu_info()
                log_msg = f"[{time.ctime()}] CPU Usage: {cpu_usage}%\n"
                try:
                    with open(LOG_FILE, "a") as f:
                        f.write(log_msg)
                except Exception as e:
                    self.log_error(f"Failed to write log: {e}")

                time.sleep(interval)
            else:
                time.sleep(10)


def main():
    collector = CPUCollector()
    collector.run()


if __name__ == "__main__":
    main()

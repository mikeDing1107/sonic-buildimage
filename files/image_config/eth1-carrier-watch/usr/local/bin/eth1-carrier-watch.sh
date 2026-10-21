#!/bin/bash
# eth1-carrier-watch: force DHCP re-negotiation when the management link
# comes up while the interface has no IPv4 address yet (e.g. management
# cable plugged in AFTER boot). Also self-heals a dead dhclient.
#
# Background (KaiTian / SONiC): isc-dhclient has no link/carrier awareness.
# If the board boots without the mgmt cable, dhclient's initial discovery
# phase times out after ~60s and it falls back to retry every 60s (custom
# retry 60; stock default is 300s). Plugging the cable later does NOT wake
# it up -> up to 1 min (stock: 5 min) delay before IP/gateway/DNS appear.
# This watcher makes the recovery immediate by re-running the interface
# configuration when it sees carrier 0 -> 1 and the interface still has no
# IPv4.
#
# NOTE: we deliberately use ifdown/ifup (instead of calling dhclient
# directly with hardcoded arguments) so the re-negotiation always follows
# the CURRENT /etc/network/interfaces config, which SONiC regenerates from
# config_db on every boot. If the mgmt interface is later configured
# statically, or if ifupdown2 changes how it invokes dhclient, this watcher
# keeps working without stale hardcoded parameters.
#
# Usage: eth1-carrier-watch.sh [iface]   (default: eth1)
IFACE=${1:-eth1}
PREV_CARRIER=""
EDGE_TS=""
LAST_ACTION=0
# ifdown/ifup flaps the link (1->0->1), which the watcher would otherwise
# see as a new link-up edge and re-trigger itself; cooldown prevents that
# loop. Also rate-limits the self-heal path.
ACTION_COOLDOWN=120

log() {
    logger -t eth1-carrier-watch "$*"
}

reconfigure_iface() {
    log "link up and no IPv4 on $IFACE, re-running interface config (ifdown/ifup)"
    /sbin/ifdown "$IFACE" >/dev/null 2>&1 || true
    sleep 1
    /sbin/ifup "$IFACE" >/dev/null 2>&1 || true
    LAST_ACTION=$(date +%s)
}

has_ipv4() {
    ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q ' inet '
}

log "eth1-carrier-watch starting (iface=$IFACE)"
while true; do
    CARRIER=$(cat /sys/class/net/$IFACE/carrier 2>/dev/null || echo 0)

    # Edge trigger: remember when the link comes up (0 -> 1)
    if [ "$CARRIER" = "1" ] && [ "$PREV_CARRIER" = "0" ]; then
        EDGE_TS=$(date +%s)
    fi
    PREV_CARRIER=$CARRIER

    # Link has been up >= 2s (debounce) and still no IPv4 -> re-run interface
    # config now. Fires at most once per link-up event (EDGE_TS cleared) and
    # is rate-limited by ACTION_COOLDOWN (ifdown/ifup flaps the link).
    if [ "$CARRIER" = "1" ] && [ -n "$EDGE_TS" ] && ! has_ipv4; then
        NOW=$(date +%s)
        if [ $((NOW - EDGE_TS)) -ge 2 ] && [ $((NOW - LAST_ACTION)) -ge "$ACTION_COOLDOWN" ]; then
            EDGE_TS=""
            reconfigure_iface
        fi
    fi

    # Self-heal: link up, no IPv4 and dhclient is not running -> reconfigure
    if [ "$CARRIER" = "1" ] && ! has_ipv4 && ! pgrep -f "/sbin/dhclient .* $IFACE" >/dev/null 2>&1; then
        NOW=$(date +%s)
        if [ $((NOW - LAST_ACTION)) -ge "$ACTION_COOLDOWN" ]; then
            reconfigure_iface
        fi
    fi

    sleep 1
done
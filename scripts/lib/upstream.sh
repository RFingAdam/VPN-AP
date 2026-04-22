#!/bin/bash
# VPN-AP shared upstream (WAN) helpers.
# Source with: . "$(dirname "$0")/lib/upstream.sh"
#
# Single source of truth for "which interface is our WAN right now?"
# Replaces the hardcoded `ip link show eth0 | grep "state UP"` pattern that
# used to live in every caller.
#
# Priority is driven by UPSTREAM_INTERFACES (space-separated, first wins).
# Default order puts the iPhone USB tether ahead of eth0 because eth0 is
# often a management-only link with no real uplink.

UPSTREAM_INTERFACES="${UPSTREAM_INTERFACES:-iphone0 eth0 wlan0}"

# Is this interface present, carrying an L1 signal, and holding a routable
# IPv4 address?
#
# We intentionally do NOT parse `ip link show ... state UP` because USB-net
# drivers (notably Apple's ipheth used for iPhone tether) leave operstate as
# "unknown" even while the link is live. /sys/class/net/<if>/carrier is the
# driver-agnostic "L1 alive" signal.
#
# `scope global` filters out loopback (scope host) and link-local addresses,
# so this also returns false for `lo` and for interfaces that only managed
# to auto-assign a 169.254.x.x address.
upstream_iface_ready() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    [ -d "/sys/class/net/$iface" ] || return 1
    [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)" = "1" ] || return 1
    ip -4 addr show "$iface" scope global 2>/dev/null | grep -q "inet " || return 1
    return 0
}

# Print this interface's IPv4 default gateway (empty if none is installed).
upstream_iface_gateway() {
    local iface="$1"
    [ -n "$iface" ] || return 0
    ip -4 route show default dev "$iface" 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}'
}

# Can we ping the interface's own gateway via that interface?
# This is the strongest signal that a candidate has real connectivity;
# works even when another interface currently owns the system default route.
upstream_iface_gateway_reachable() {
    local iface="$1"
    local gw
    gw="$(upstream_iface_gateway "$iface")"
    [ -n "$gw" ] || return 1
    timeout 2 ping -I "$iface" -c 1 -W 1 "$gw" >/dev/null 2>&1
}

# Print the interface currently owning the IPv4 default route (empty if none).
upstream_default_route_iface() {
    ip -4 route show default 0.0.0.0/0 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# 2-of-3 reachability probe to well-known anycast DNS via the current default
# route. Call this after select_upstream has picked a candidate and the
# routing has been committed.
upstream_has_connectivity() {
    local ok=0
    local target
    for target in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if timeout 2 ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
            ok=$((ok + 1))
            [ "$ok" -ge 2 ] && return 0
        fi
    done
    return 1
}

# Return the winning upstream interface for UPSTREAM_INTERFACES.
# Three passes, strictest first:
#   1) ready AND gateway is actually reachable  (real uplink)
#   2) ready AND has a gateway configured        (plausible uplink)
#   3) ready                                     (best guess, may be dead)
# Prints the winner to stdout; returns 1 if nothing is even ready.
select_upstream() {
    local iface
    for iface in $UPSTREAM_INTERFACES; do
        if upstream_iface_ready "$iface" && upstream_iface_gateway_reachable "$iface"; then
            echo "$iface"; return 0
        fi
    done
    for iface in $UPSTREAM_INTERFACES; do
        if upstream_iface_ready "$iface" && [ -n "$(upstream_iface_gateway "$iface")" ]; then
            echo "$iface"; return 0
        fi
    done
    for iface in $UPSTREAM_INTERFACES; do
        if upstream_iface_ready "$iface"; then
            echo "$iface"; return 0
        fi
    done
    return 1
}

# Back-compat name used by older scripts.
get_best_upstream() { select_upstream; }

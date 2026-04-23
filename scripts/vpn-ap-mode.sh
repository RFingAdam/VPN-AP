#!/bin/bash
# vpn-ap-mode — switch the AP radio between single-band and dual-band layouts.
#
# Usage:
#   vpn-ap-mode              # print current mode
#   vpn-ap-mode status       # verbose status
#   vpn-ap-mode single       # one AP on the USB adapter (wlan1 2.4 GHz),
#                            # Pi built-in (wlan0) free to be upstream client
#   vpn-ap-mode dual         # two APs: wlan0 = 2.4 GHz (long range),
#                            # wlan1 = 5 GHz (speed); no wlan0 upstream
#
# State file: /etc/default/vpn-ap  (AP_MODE=single|dual)
#
# What happens on mode change:
#   - NM control of wlan0: released in dual mode, restored in single mode
#   - Runtime hostapd configs written to /run/vpn-ap/hostapd-<iface>.conf
#   - Stock hostapd.service stopped; our vpn-ap-hostapd@<iface>.service(s)
#     managed based on mode
#   - Static IPs assigned to AP interface(s)
#   - dnsmasq config swapped (single: vpn-ap.conf, dual: vpn-ap-dual.conf)
#   - iptables re-applied via iptables-internet-mode.sh so FORWARD + NAT
#     cover both AP subnets in dual mode

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEFAULTS=/etc/default/vpn-ap
RUNDIR=/run/vpn-ap
NM_WLAN0_CONN="ItBurnsWhenIP"          # default; overridable below
HOSTAPD_24_TMPL=/etc/hostapd/hostapd.conf
HOSTAPD_5G_TMPL=/etc/hostapd/hostapd-5g.conf
DNSMASQ_SINGLE=/etc/dnsmasq.d/vpn-ap.conf
DNSMASQ_DUAL_ACTIVE=/etc/dnsmasq.d/vpn-ap-dual.conf
DNSMASQ_DUAL_SRC=/usr/local/lib/vpn-ap/dnsmasq-dual.conf
DNSMASQ_BACKUP=/etc/vpn-ap/dnsmasq-inactive
IPTABLES_INTERNET=/usr/local/bin/iptables-internet-mode.sh

# Load config defaults (allow env override)
# shellcheck source=/dev/null
[ -f "$DEFAULTS" ] && . "$DEFAULTS"

AP_24_IFACE="${AP_24_IFACE:-wlan0}"    # which iface holds the 2.4 GHz AP in dual mode
AP_5G_IFACE="${AP_5G_IFACE:-wlan1}"    # which iface holds the 5 GHz AP in dual mode
AP_SINGLE_IFACE="${AP_INTERFACE:-wlan1}"  # single-mode AP interface (legacy AP_INTERFACE)
NM_WLAN0_CONN="${NM_WLAN0_CONN:-}"      # empty = auto-detect from NM

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Must run as root (use sudo).${NC}" >&2
        exit 1
    fi
}

log_warn() {
    echo -e "  ${YELLOW}$*${NC}" >&2
}

current_mode() {
    # Honor AP_MODE from defaults; fall back to single.
    echo "${AP_MODE:-single}"
}

# Render a per-interface hostapd config by substituting the interface name
# into the user-editable template.
render_hostapd_config() {
    local template="$1" iface="$2" outfile="$3"
    if [ ! -f "$template" ]; then
        echo -e "${RED}Missing hostapd template: $template${NC}" >&2
        return 1
    fi
    mkdir -p "$RUNDIR"
    sed "s/^interface=.*/interface=$iface/; s/__VPN_AP_IFACE__/$iface/" "$template" > "$outfile"
    chmod 600 "$outfile"
}

# Pick the NM connection name bound to wlan0, if we need to restore it.
detect_nm_wlan0_conn() {
    if [ -n "$NM_WLAN0_CONN" ]; then
        echo "$NM_WLAN0_CONN"
        return
    fi
    nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless" && ($3=="wlan0" || $3=="") {print $1; exit}'
}

stop_all_aps() {
    # Stop the stock hostapd service if running, and any of our instances.
    systemctl stop hostapd 2>/dev/null || true
    systemctl disable hostapd 2>/dev/null || true
    # Template units: stop all known instances. We only ever use wlan0/wlan1.
    systemctl stop 'vpn-ap-hostapd@wlan0' 'vpn-ap-hostapd@wlan1' 2>/dev/null || true
    # Clear any systemd "start-request-too-quickly" backoff state so the
    # next start call isn't rejected.
    systemctl reset-failed 'vpn-ap-hostapd@wlan0' 'vpn-ap-hostapd@wlan1' 2>/dev/null || true
    # Kill any dangling hostapd processes that survived the service stop.
    pkill -9 -f '^/usr/sbin/hostapd.*/run/vpn-ap/' 2>/dev/null || true
}

write_ap_interfaces_to_defaults() {
    # Persist AP_MODE + AP_INTERFACES (space-separated) + AP_SUBNETS so the
    # iptables scripts and watchdog can pick them up.
    local mode="$1" ifaces="$2" subnets="$3"
    if grep -q '^AP_MODE=' "$DEFAULTS" 2>/dev/null; then
        sed -i "s|^AP_MODE=.*|AP_MODE=$mode|" "$DEFAULTS"
    else
        echo "AP_MODE=$mode" >> "$DEFAULTS"
    fi
    if grep -q '^AP_INTERFACES=' "$DEFAULTS" 2>/dev/null; then
        sed -i "s|^AP_INTERFACES=.*|AP_INTERFACES=\"$ifaces\"|" "$DEFAULTS"
    else
        echo "AP_INTERFACES=\"$ifaces\"" >> "$DEFAULTS"
    fi
    if grep -q '^AP_SUBNETS=' "$DEFAULTS" 2>/dev/null; then
        sed -i "s|^AP_SUBNETS=.*|AP_SUBNETS=\"$subnets\"|" "$DEFAULTS"
    else
        echo "AP_SUBNETS=\"$subnets\"" >> "$DEFAULTS"
    fi
}

switch_to_single() {
    echo -e "${GREEN}Switching to SINGLE-AP mode (wlan1 = 2.4 GHz, wlan0 free for upstream)${NC}"
    stop_all_aps

    # Clear any static IP we put on wlan0 in dual mode.
    ip addr flush dev wlan0 2>/dev/null || true

    # Restore NM control of wlan0 so home-WiFi connection can come back.
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set wlan0 managed yes 2>/dev/null || true
        local conn
        conn=$(detect_nm_wlan0_conn)
        if [ -n "$conn" ]; then
            nmcli connection up "$conn" ifname wlan0 2>/dev/null || \
                echo -e "  ${YELLOW}(could not bring up '$conn' on wlan0 — you can start it manually)${NC}"
        fi
    fi

    # Single-mode runtime hostapd config on wlan1 (2.4 GHz).
    render_hostapd_config "$HOSTAPD_24_TMPL" "$AP_SINGLE_IFACE" "$RUNDIR/hostapd-$AP_SINGLE_IFACE.conf"

    # Ensure the AP interface has its static IP.
    ip addr flush dev "$AP_SINGLE_IFACE" 2>/dev/null || true
    ip addr add 192.168.4.1/24 dev "$AP_SINGLE_IFACE"
    ip link set "$AP_SINGLE_IFACE" up

    # Single-mode dnsmasq config: remove the dual config (dnsmasq.d reads ALL
    # files regardless of extension, so we must MOVE the inactive one out of
    # that directory, not just rename it). Restore the single-mode config
    # from backup if it was parked.
    mkdir -p "$DNSMASQ_BACKUP"
    [ -f "$DNSMASQ_DUAL_ACTIVE" ] && mv "$DNSMASQ_DUAL_ACTIVE" "$DNSMASQ_BACKUP/vpn-ap-dual.conf"
    if [ ! -f "$DNSMASQ_SINGLE" ] && [ -f "$DNSMASQ_BACKUP/vpn-ap.conf" ]; then
        mv "$DNSMASQ_BACKUP/vpn-ap.conf" "$DNSMASQ_SINGLE"
    fi
    systemctl restart dnsmasq || log_warn "dnsmasq restart failed (non-fatal); check: systemctl status dnsmasq"

    # Start our AP instance on wlan1.
    systemctl enable --now "vpn-ap-hostapd@$AP_SINGLE_IFACE" 2>/dev/null || \
        systemctl start "vpn-ap-hostapd@$AP_SINGLE_IFACE"

    write_ap_interfaces_to_defaults "single" "$AP_SINGLE_IFACE" "192.168.4.0/24"

    # Re-apply firewall so FORWARD/NAT know about the new AP layout.
    if [ -x "$IPTABLES_INTERNET" ]; then
        "$IPTABLES_INTERNET" || true
    fi

    echo -e "${GREEN}Single-AP mode active: $AP_SINGLE_IFACE = 2.4 GHz${NC}"
}

switch_to_dual() {
    echo -e "${GREEN}Switching to DUAL-AP mode (wlan0 = 2.4 GHz, wlan1 = 5 GHz)${NC}"
    stop_all_aps

    # Release wlan0 from NetworkManager so we can run hostapd on it.
    if command -v nmcli >/dev/null 2>&1; then
        local conn
        conn=$(detect_nm_wlan0_conn)
        if [ -n "$conn" ]; then
            nmcli connection down "$conn" 2>/dev/null || true
        fi
        nmcli device set wlan0 managed no 2>/dev/null || true
        nmcli device disconnect wlan0 2>/dev/null || true
    fi

    # Make sure both radios are up and admin-enabled.
    rfkill unblock wifi 2>/dev/null || true
    ip link set "$AP_24_IFACE" up 2>/dev/null || true
    ip link set "$AP_5G_IFACE" up 2>/dev/null || true

    # Render per-interface runtime configs.
    render_hostapd_config "$HOSTAPD_24_TMPL" "$AP_24_IFACE" "$RUNDIR/hostapd-$AP_24_IFACE.conf"
    render_hostapd_config "$HOSTAPD_5G_TMPL" "$AP_5G_IFACE" "$RUNDIR/hostapd-$AP_5G_IFACE.conf"

    # Static IPs on both AP interfaces on different subnets.
    ip addr flush dev "$AP_24_IFACE" 2>/dev/null || true
    ip addr add 192.168.4.1/24 dev "$AP_24_IFACE"
    ip addr flush dev "$AP_5G_IFACE" 2>/dev/null || true
    ip addr add 192.168.5.1/24 dev "$AP_5G_IFACE"

    # Install dual-mode dnsmasq config (serves DHCP on both interfaces).
    # dnsmasq.d reads EVERY file in the dir (extension ignored), so we must
    # MOVE the single-mode config OUT of the dir, not just rename it.
    mkdir -p "$DNSMASQ_BACKUP"
    if [ -f "$DNSMASQ_DUAL_SRC" ]; then
        cp "$DNSMASQ_DUAL_SRC" "$DNSMASQ_DUAL_ACTIVE"
        if [ -f "$DNSMASQ_SINGLE" ]; then
            mv "$DNSMASQ_SINGLE" "$DNSMASQ_BACKUP/vpn-ap.conf"
        fi
        # Also purge any leftover in-place-renamed files from an earlier
        # buggy version of this script.
        rm -f /etc/dnsmasq.d/vpn-ap.conf.single-disabled /etc/dnsmasq.d/vpn-ap.conf.dual-disabled
        systemctl restart dnsmasq || log_warn "dnsmasq restart failed (non-fatal); check: systemctl status dnsmasq"
    else
        echo -e "  ${YELLOW}Warning: $DNSMASQ_DUAL_SRC not found; dnsmasq left untouched${NC}"
    fi

    # Start both AP instances.
    systemctl enable --now "vpn-ap-hostapd@$AP_24_IFACE" "vpn-ap-hostapd@$AP_5G_IFACE" 2>/dev/null || \
        systemctl start "vpn-ap-hostapd@$AP_24_IFACE" "vpn-ap-hostapd@$AP_5G_IFACE"

    write_ap_interfaces_to_defaults "dual" "$AP_24_IFACE $AP_5G_IFACE" "192.168.4.0/24 192.168.5.0/24"

    if [ -x "$IPTABLES_INTERNET" ]; then
        "$IPTABLES_INTERNET" || true
    fi

    echo -e "${GREEN}Dual-AP mode active:${NC}"
    echo "  $AP_24_IFACE = 2.4 GHz (192.168.4.0/24)"
    echo "  $AP_5G_IFACE = 5 GHz   (192.168.5.0/24)"
    echo -e "  ${YELLOW}Note: wlan0 is now an AP, so it cannot be used as upstream WiFi.${NC}"
    echo "        Upstream will be iPhone USB tether (iphone0), Ethernet (eth0), or HaLow."
}

status() {
    local mode
    mode=$(current_mode)
    echo "AP_MODE: $mode"
    echo "Configured AP interfaces: ${AP_INTERFACES:-unset}"
    echo "Configured AP subnets:    ${AP_SUBNETS:-unset}"
    echo ""
    echo "== hostapd instances =="
    for iface in wlan0 wlan1; do
        printf "  vpn-ap-hostapd@%s: " "$iface"
        systemctl is-active "vpn-ap-hostapd@$iface" 2>/dev/null || true
    done
    echo ""
    echo "== AP interface IPs =="
    for iface in wlan0 wlan1; do
        ip -4 -br addr show "$iface" 2>/dev/null | head -1 || true
    done
    echo ""
    echo "== dnsmasq =="
    systemctl is-active dnsmasq || true
    echo ""
    echo "== upstream pick right now =="
    if [ -f /usr/local/lib/vpn-ap/upstream.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/vpn-ap/upstream.sh
        select_upstream 2>/dev/null || echo "(none)"
    fi
}

case "${1:-status}" in
    single|sing|1)  require_root; switch_to_single ;;
    dual|2)         require_root; switch_to_dual ;;
    status|"")      status ;;
    -h|--help|help)
        echo "Usage: $0 {single|dual|status}"
        exit 0
        ;;
    *)
        echo "Unknown mode: $1" >&2
        echo "Usage: $0 {single|dual|status}" >&2
        exit 2
        ;;
esac

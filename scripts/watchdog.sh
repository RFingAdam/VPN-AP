#!/bin/bash
# VPN-AP Watchdog - Monitors services and auto-recovers from failures
# Runs every minute via systemd timer to ensure system stays operational.

set -u
set -o pipefail

LOGFILE="/var/log/vpn-ap-watchdog.log"
STATE_DIR="/var/lib/vpn-ap"
MAX_LOG_SIZE=1048576  # 1MB

# Defaults; any of these may be overridden by /etc/default/vpn-ap via the
# systemd unit's EnvironmentFile.
UPSTREAM_INTERFACES="${UPSTREAM_INTERFACES:-iphone0 eth0 wlan0}"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
VPN_START_CMD="${VPN_START_CMD:-/usr/local/bin/vpn-start}"
AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"
MAX_RECOVERY_ATTEMPTS_PER_DAY=5    # Per-service attempt cap
ESCALATE_AT_COUNT=3                 # hostapd attempts before escalation

# AP_MODE governs single vs dual band AP. AP_INTERFACES / AP_SUBNETS carry
# the per-interface layout set by `vpn-ap-mode`. Legacy single-AP fallbacks
# keep old configs working if the file hasn't been re-written.
AP_MODE="${AP_MODE:-single}"
AP_INTERFACES="${AP_INTERFACES:-$AP_IF}"
AP_SUBNETS="${AP_SUBNETS:-192.168.4.0/24}"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Source shared upstream helper. This provides select_upstream,
# upstream_iface_ready, upstream_has_connectivity, upstream_default_route_iface.
_VPN_AP_LIB="${VPN_AP_LIB:-/usr/local/lib/vpn-ap}"
[ -r "$_VPN_AP_LIB/upstream.sh" ] || _VPN_AP_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
# shellcheck source=lib/upstream.sh
. "$_VPN_AP_LIB/upstream.sh"

# Timeout wrappers to prevent watchdog from hanging indefinitely.
sctl() { timeout 30 systemctl "$@" 2>/dev/null; }
ipt()  { timeout 10 iptables "$@" 2>/dev/null; }

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
    # Rotate log if too large (keep 3 history files)
    local size
    size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
        [ -f "${LOGFILE}.1" ] && mv "${LOGFILE}.1" "${LOGFILE}.2"
        [ -f "${LOGFILE}.old" ] && mv "${LOGFILE}.old" "${LOGFILE}.1"
        mv "$LOGFILE" "${LOGFILE}.old"
    fi
}

# Read a string value from the portal-state JSON. Returns empty on any error.
read_portal_state() {
    local key="$1"
    local state_file="$STATE_DIR/portal-state.json"
    [ -f "$state_file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // ""' "$state_file" 2>/dev/null || true
    else
        # Last-resort fallback — jq should always be present (setup.sh installs it).
        python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2],''))
except Exception:
    pass" "$state_file" "$key" 2>/dev/null || true
    fi
}

# Per-service recovery attempt tracking. Counters reset daily by
# vpn-ap-reset-counters.timer, not by an in-tick date compare.
increment_recovery_count() {
    local service="$1"
    local count_file="$STATE_DIR/${service}_recovery_count"
    local count
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$count_file"
    echo "$count"
}

reset_recovery_count() {
    local service="$1"
    rm -f "$STATE_DIR/${service}_recovery_count"
}

get_recovery_count() {
    local service="$1"
    cat "$STATE_DIR/${service}_recovery_count" 2>/dev/null || echo 0
}

# Return the gateway IP for an AP subnet (first host — .1).
_ap_gw_for_subnet() {
    echo "$1" | awk -F/ '{print $1}' | awk -F. '{printf "%s.%s.%s.1\n", $1,$2,$3}'
}

# Check that each configured AP interface has its static gateway IP. Works
# identically in single-AP and dual-AP mode.
check_ap_interface() {
    local iface subnet gw ok=0
    # shellcheck disable=SC2206
    local ifaces_arr=($AP_INTERFACES)
    # shellcheck disable=SC2206
    local subnets_arr=($AP_SUBNETS)
    for i in "${!ifaces_arr[@]}"; do
        iface="${ifaces_arr[$i]}"
        subnet="${subnets_arr[$i]:-${subnets_arr[0]:-192.168.4.0/24}}"
        gw=$(_ap_gw_for_subnet "$subnet")
        if ! ip addr show "$iface" 2>/dev/null | grep -q "$gw"; then
            log "WARN: AP interface $iface missing or wrong IP (expected $gw)"
            ok=1
        fi
    done
    return "$ok"
}

# In single-AP mode we still support the stock hostapd.service for backward
# compatibility with pre-v1.6 installs. In dual-AP mode we rely on our
# per-interface template units.
check_hostapd() {
    if [ "$AP_MODE" = "dual" ]; then
        local iface any_down=0
        for iface in $AP_INTERFACES; do
            if ! sctl is-active --quiet "vpn-ap-hostapd@$iface"; then
                log "WARN: vpn-ap-hostapd@$iface is not running"
                any_down=1
            fi
        done
        if [ "$any_down" -eq 1 ]; then
            return 1
        fi
    else
        # Single mode: accept EITHER the stock hostapd.service or the
        # vpn-ap-hostapd@<iface> template unit as authoritative.
        if ! sctl is-active --quiet hostapd && \
           ! sctl is-active --quiet "vpn-ap-hostapd@$AP_IF"; then
            log "WARN: hostapd is not running (neither stock nor vpn-ap-hostapd@$AP_IF)"
            return 1
        fi
    fi
    if ! iw dev 2>/dev/null | grep -q "type AP"; then
        log "WARN: No AP mode interface detected"
        return 1
    fi
    return 0
}

check_dnsmasq() {
    if ! sctl is-active --quiet dnsmasq; then
        log "WARN: dnsmasq is not running"
        return 1
    fi
    # Every 5th minute, verify DNS actually resolves (only if we have an upstream).
    if [ $(( $(date +%M) % 5 )) -eq 0 ] && check_upstream; then
        if ! timeout 3 nslookup google.com 192.168.4.1 >/dev/null 2>&1; then
            log "WARN: dnsmasq running but DNS resolution failed"
            return 1
        fi
    fi
    return 0
}

check_portal() {
    if ! sctl is-active --quiet captive-portal; then
        log "WARN: captive-portal is not running"
        return 1
    fi
    if ! ss -tlnp 2>/dev/null | grep -q ":80 "; then
        log "WARN: Nothing listening on port 80"
        return 1
    fi
    return 0
}

# "Do we have any upstream connectivity right now?"
# Any candidate interface ready + the 2-of-3 reachability probe passes.
check_upstream() {
    local iface any_ready=0
    for iface in $UPSTREAM_INTERFACES; do
        if upstream_iface_ready "$iface"; then
            any_ready=1
            break
        fi
    done
    if [ "$any_ready" -eq 0 ]; then
        return 1
    fi
    if ! upstream_has_connectivity; then
        log "WARN: Upstream interface up but connectivity weak (2-of-3 probe failed)"
        return 1
    fi
    return 0
}

check_vpn() {
    if command -v nordvpn >/dev/null 2>&1; then
        if timeout 10 nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
            return 0
        fi
    fi
    if ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "UP"; then
        return 0
    fi
    return 1
}

check_vpn_health() {
    check_vpn || return 1
    # Ping through VPN to verify tunnel passes traffic.
    if ! timeout 5 ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log "WARN: VPN connected but tunnel not passing traffic"
        return 1
    fi
    return 0
}

recover_vpn() {
    local count
    count=$(increment_recovery_count "vpn")
    if [ "$count" -gt "$MAX_RECOVERY_ATTEMPTS_PER_DAY" ]; then
        log "ERROR: Too many VPN recovery attempts today (${count}), skipping"
        return 1
    fi
    log "INFO: Attempting VPN recovery (attempt $count)"

    if command -v nordvpn >/dev/null 2>&1; then
        timeout 10 nordvpn disconnect >/dev/null 2>&1 || true
    fi
    sleep 2

    if [ -x "$VPN_START_CMD" ]; then
        if "$VPN_START_CMD" >/dev/null 2>&1; then
            sleep 5
            if check_vpn_health; then
                log "INFO: VPN recovery successful"
                reset_recovery_count "vpn"
                return 0
            fi
            log "ERROR: VPN reconnected but health check failed"
            return 1
        fi
        log "ERROR: VPN start command failed"
        return 1
    fi

    # Fallback: try nordvpn connect directly to the last server (if saved).
    if command -v nordvpn >/dev/null 2>&1; then
        local server
        server="$(read_portal_state last_vpn_server)"
        local -a cmd=(nordvpn connect)
        [ -n "$server" ] && cmd=(nordvpn connect "$server")
        if timeout 30 "${cmd[@]}" >/dev/null 2>&1; then
            sleep 5
            if check_vpn_health; then
                log "INFO: VPN recovery successful"
                reset_recovery_count "vpn"
                return 0
            fi
        fi
    fi
    log "ERROR: VPN recovery failed"
    return 1
}

recover_wifi() {
    local count
    count=$(increment_recovery_count "wifi")
    if [ "$count" -gt "$MAX_RECOVERY_ATTEMPTS_PER_DAY" ]; then
        log "ERROR: Too many WiFi recovery attempts today (${count}), skipping"
        return 1
    fi

    local ssid
    ssid="$(read_portal_state last_wifi_ssid)"
    if [ -z "$ssid" ]; then
        log "WARN: No last WiFi SSID found for recovery"
        return 1
    fi

    log "INFO: Attempting WiFi recovery for '$ssid' (attempt $count)"

    local upstream_if="${UPSTREAM_IF:-wlan0}"
    local conn_name="vpn-ap-${ssid}"

    if timeout 45 nmcli connection up "$conn_name" ifname "$upstream_if" >/dev/null 2>&1; then
        sleep 3
        if ip addr show "$upstream_if" 2>/dev/null | grep -q "inet "; then
            log "INFO: WiFi recovery successful for '$ssid'"
            reset_recovery_count "wifi"
            return 0
        fi
    fi

    # Fallback: try by SSID directly.
    if timeout 45 nmcli connection up "$ssid" ifname "$upstream_if" >/dev/null 2>&1; then
        sleep 3
        if ip addr show "$upstream_if" 2>/dev/null | grep -q "inet "; then
            log "INFO: WiFi recovery successful for '$ssid' (by SSID)"
            reset_recovery_count "wifi"
            return 0
        fi
    fi

    log "ERROR: WiFi recovery failed for '$ssid'"
    return 1
}

maybe_restart_vpn_on_upstream_change() {
    local current_upstream
    current_upstream="$(select_upstream 2>/dev/null || true)"
    [ -n "$current_upstream" ] || return 0

    local last_upstream
    last_upstream="$(cat "$STATE_DIR/last_upstream" 2>/dev/null || echo "")"

    if [ -n "$last_upstream" ] && [ "$current_upstream" != "$last_upstream" ]; then
        if check_vpn; then
            if [ -x "$VPN_START_CMD" ]; then
                log "INFO: Upstream changed from ${last_upstream} to ${current_upstream}. Restarting VPN..."
                VPN_FORCE_RECONNECT=1 "$VPN_START_CMD" >/dev/null 2>&1 || \
                    log "ERROR: VPN restart failed after upstream change"
            else
                log "WARN: VPN start command not found: $VPN_START_CMD"
            fi
        fi
    fi

    echo "$current_upstream" > "$STATE_DIR/last_upstream"
}

recover_ap_interface() {
    local count
    count=$(increment_recovery_count "ap_interface")
    if [ "$count" -gt "$MAX_RECOVERY_ATTEMPTS_PER_DAY" ]; then
        log "ERROR: Too many AP interface recovery attempts today (${count}), skipping"
        return 1
    fi

    log "INFO: Attempting AP interface recovery (attempt $count)"
    rfkill unblock wifi 2>/dev/null || true

    # Re-apply the static gateway IP on every configured AP interface, using
    # AP_SUBNETS to derive the right /24.1 for each.
    # shellcheck disable=SC2206
    local ifaces_arr=($AP_INTERFACES)
    # shellcheck disable=SC2206
    local subnets_arr=($AP_SUBNETS)
    local i iface subnet gw
    for i in "${!ifaces_arr[@]}"; do
        iface="${ifaces_arr[$i]}"
        subnet="${subnets_arr[$i]:-${subnets_arr[0]:-192.168.4.0/24}}"
        gw=$(_ap_gw_for_subnet "$subnet")
        ip link set "$iface" up 2>/dev/null || true
        sleep 1
        ip addr flush dev "$iface" 2>/dev/null || true
        ip addr add "${gw}/24" dev "$iface" 2>/dev/null || true
    done
    log "INFO: AP interface recovery completed"
    return 0
}

recover_hostapd() {
    local count
    count=$(increment_recovery_count "hostapd")
    if [ "$count" -gt "$MAX_RECOVERY_ATTEMPTS_PER_DAY" ]; then
        log "ERROR: Too many hostapd recovery attempts today (${count}), skipping"
        return 1
    fi

    log "INFO: Attempting hostapd recovery (attempt $count, mode=$AP_MODE)"

    if [ "$AP_MODE" = "dual" ]; then
        local iface
        for iface in $AP_INTERFACES; do
            sctl stop "vpn-ap-hostapd@$iface" || true
        done
        sleep 1
        recover_ap_interface
        sleep 1
        for iface in $AP_INTERFACES; do
            sctl start "vpn-ap-hostapd@$iface"
        done
        sleep 2
        local all_up=1
        for iface in $AP_INTERFACES; do
            sctl is-active --quiet "vpn-ap-hostapd@$iface" || all_up=0
        done
        if [ "$all_up" -eq 1 ]; then
            log "INFO: hostapd recovery successful (dual mode)"
            reset_recovery_count "hostapd"
            return 0
        fi
        log "ERROR: hostapd recovery failed (dual mode)"
        return 1
    fi

    # Single-mode path
    sctl stop hostapd || true
    sctl stop "vpn-ap-hostapd@$AP_IF" || true
    sleep 1
    recover_ap_interface
    sleep 1
    # Prefer the template unit if it's enabled, else fall back to stock hostapd
    if [ -L "/etc/systemd/system/multi-user.target.wants/vpn-ap-hostapd@${AP_IF}.service" ] || \
       sctl list-unit-files "vpn-ap-hostapd@${AP_IF}.service" 2>/dev/null | grep -q enabled; then
        sctl start "vpn-ap-hostapd@$AP_IF"
    else
        sctl start hostapd
    fi
    sleep 2

    if sctl is-active --quiet hostapd || sctl is-active --quiet "vpn-ap-hostapd@$AP_IF"; then
        log "INFO: hostapd recovery successful"
        reset_recovery_count "hostapd"
        return 0
    fi
    log "ERROR: hostapd recovery failed"
    return 1
}

recover_dnsmasq() {
    local count
    count=$(increment_recovery_count "dnsmasq")
    if [ "$count" -gt "$MAX_RECOVERY_ATTEMPTS_PER_DAY" ]; then
        log "ERROR: Too many dnsmasq recovery attempts today (${count}), skipping"
        return 1
    fi

    log "INFO: Attempting dnsmasq recovery (attempt $count)"
    sctl restart dnsmasq
    sleep 1
    if sctl is-active --quiet dnsmasq; then
        log "INFO: dnsmasq recovery successful"
        reset_recovery_count "dnsmasq"
        return 0
    fi
    log "ERROR: dnsmasq recovery failed"
    return 1
}

recover_portal() {
    local count
    count=$(increment_recovery_count "portal")
    if [ "$count" -gt "$MAX_RECOVERY_ATTEMPTS_PER_DAY" ]; then
        log "ERROR: Too many portal recovery attempts today (${count}), skipping"
        return 1
    fi

    log "INFO: Attempting portal recovery (attempt $count)"
    pkill -f captive-portal-server.py 2>/dev/null || true
    sleep 1
    sctl restart captive-portal
    sleep 2

    if sctl is-active --quiet captive-portal; then
        log "INFO: Portal recovery successful"
        reset_recovery_count "portal"
        return 0
    fi
    log "ERROR: Portal recovery failed"
    return 1
}

reinforce_power_save_off() {
    local ap_if="${AP_IF:-wlan1}"
    iw dev "$ap_if" set power_save off 2>/dev/null || true
}

# Escalation: full AP-subsystem reset when hostapd normal recovery is exhausted.
# No separate escalation counter — the hostapd daily count cap is the gate.
escalate_ap_recovery() {
    local ap_if="${AP_IF:-wlan1}"
    log "WARN: Escalating to full AP recovery - reloading wireless subsystem"

    sctl stop hostapd || true
    sctl stop dnsmasq || true
    sleep 2

    rfkill unblock wifi 2>/dev/null || true
    ip link set "$ap_if" down 2>/dev/null || true
    sleep 2
    ip link set "$ap_if" up 2>/dev/null || true
    sleep 2
    iw dev "$ap_if" set power_save off 2>/dev/null || true
    ip addr flush dev "$ap_if" 2>/dev/null || true
    ip addr add 192.168.4.1/24 dev "$ap_if" 2>/dev/null || true
    sleep 1

    sctl start hostapd
    sleep 3
    sctl start dnsmasq
    sleep 1

    if sctl is-active --quiet hostapd && iw dev 2>/dev/null | grep -q "type AP"; then
        log "INFO: Full AP recovery successful - AP is broadcasting"
        reset_recovery_count "ap_interface"
        reset_recovery_count "hostapd"
        reset_recovery_count "dnsmasq"
        return 0
    fi
    log "ERROR: Full AP recovery failed - manual intervention may be needed"
    return 1
}

ensure_ssh_access() {
    if ! sctl is-active --quiet ssh; then
        log "WARN: SSH not running, starting..."
        sctl start ssh
    fi
    ipt -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    ipt -I INPUT 1 -p tcp --dport 22 -j ACCEPT
}

ensure_management_access() {
    ensure_ssh_access
    # Re-insert critical portal + DHCP + DNS ACCEPTs on every AP interface.
    # Delete-before-insert prevents rule accumulation across watchdog ticks.
    local ap_if
    local slot=2
    for ap_if in $AP_INTERFACES; do
        ipt -D INPUT -i "$ap_if" -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        ipt -I INPUT "$slot" -i "$ap_if" -p tcp --dport 80 -j ACCEPT
        slot=$((slot + 1))
        ipt -D INPUT -i "$ap_if" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
        ipt -I INPUT "$slot" -i "$ap_if" -p udp --dport 67 -j ACCEPT
        slot=$((slot + 1))
        ipt -D INPUT -i "$ap_if" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        ipt -I INPUT "$slot" -i "$ap_if" -p udp --dport 53 -j ACCEPT
        slot=$((slot + 1))
    done
}

main() {
    log "INFO: Watchdog check starting"

    local issues_found=0

    ensure_management_access
    reinforce_power_save_off

    if ! check_ap_interface; then
        recover_ap_interface
        issues_found=1
    fi

    if ! check_hostapd; then
        if ! recover_hostapd; then
            local hostapd_count
            hostapd_count=$(get_recovery_count "hostapd")
            if [ "$hostapd_count" -ge "$ESCALATE_AT_COUNT" ]; then
                log "WARN: Normal hostapd recovery exhausted at count=$hostapd_count, escalating..."
                escalate_ap_recovery
            fi
        fi
        issues_found=1
    fi

    if ! check_dnsmasq; then
        recover_dnsmasq
        issues_found=1
    fi

    if ! check_portal; then
        recover_portal
        issues_found=1
    fi

    # WiFi - reconnect if dropped and we have a saved SSID
    local upstream_if="${UPSTREAM_IF:-wlan0}"
    local wifi_up=0
    if ip link show "$upstream_if" 2>/dev/null | grep -q "state UP"; then
        if ip addr show "$upstream_if" 2>/dev/null | grep -q "inet "; then
            wifi_up=1
        fi
    fi

    if [ "$wifi_up" -eq 0 ]; then
        local saved_ssid
        saved_ssid="$(read_portal_state last_wifi_ssid)"
        if [ -n "$saved_ssid" ]; then
            log "WARN: WiFi disconnected but saved SSID '$saved_ssid' exists, attempting recovery..."
            recover_wifi
            issues_found=1
        fi
    fi

    # VPN - recover if it should be active but isn't.
    if [ -f "$STATE_DIR/vpn_should_be_active" ]; then
        if ! check_vpn_health; then
            log "WARN: VPN should be active but is down/unhealthy, attempting recovery..."
            recover_vpn
            issues_found=1
        fi
    fi

    # Restart VPN if upstream changes while connected.
    maybe_restart_vpn_on_upstream_change

    if [ "$issues_found" -eq 0 ]; then
        # Only log healthy status every 10 minutes to reduce noise.
        if [ $(( $(date +%M) % 10 )) -eq 0 ]; then
            log "INFO: All services healthy"
        fi
    fi

    date +%s > "$STATE_DIR/last_watchdog_check"
}

main "$@"

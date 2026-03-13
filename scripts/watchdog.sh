#!/bin/bash
# VPN-AP Watchdog - Monitors services and auto-recovers from failures
# Runs every minute via systemd timer to ensure system stays operational

set -o pipefail

LOGFILE="/var/log/vpn-ap-watchdog.log"
STATE_DIR="/var/lib/vpn-ap"
MAX_LOG_SIZE=1048576  # 1MB
UPSTREAM_INTERFACES="${UPSTREAM_INTERFACES:-eth0 wlan0}"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
VPN_START_CMD="${VPN_START_CMD:-/usr/local/bin/vpn-start}"
MAX_ESCALATIONS=3

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Timeout wrappers to prevent watchdog from hanging
sctl() { timeout 30 systemctl "$@" 2>/dev/null; }
ipt() { timeout 10 iptables "$@" 2>/dev/null; }

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
    # Rotate log if too large (keep 3 history files)
    local log_size
    log_size=$(stat -f%z "$LOGFILE" 2>/dev/null || stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ -f "$LOGFILE" ] && [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
        [ -f "${LOGFILE}.1" ] && mv "${LOGFILE}.1" "${LOGFILE}.2"
        [ -f "${LOGFILE}.old" ] && mv "${LOGFILE}.old" "${LOGFILE}.1"
        mv "$LOGFILE" "${LOGFILE}.old"
    fi
}

get_default_route_interface() {
    ip route show default 0.0.0.0/0 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }'
}

get_best_upstream() {
    local iface
    iface="$(get_default_route_interface)"
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi

    for iface in $UPSTREAM_INTERFACES; do
        if ip link show "$iface" >/dev/null 2>&1; then
            if ip link show "$iface" | grep -q "state UP"; then
                echo "$iface"
                return 0
            fi
        fi
    done

    return 1
}

# Track recovery attempts to avoid infinite loops
increment_recovery_count() {
    local service="$1"
    local count_file="$STATE_DIR/${service}_recovery_count"
    local count=$(cat "$count_file" 2>/dev/null || echo 0)
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

# Exponential backoff: check if enough time has elapsed since last recovery attempt
should_attempt_recovery() {
    local service="$1"
    local ts_file="$STATE_DIR/${service}_last_recovery"
    local count=$(get_recovery_count "$service")
    local now=$(date +%s)
    local last=$(cat "$ts_file" 2>/dev/null || echo 0)

    # Backoff: 60s, 120s, 240s, 480s, 960s (capped at 960s / 16 min)
    local delay=60
    local i=0
    while [ "$i" -lt "$count" ] && [ "$delay" -lt 960 ]; do
        delay=$((delay * 2))
        i=$((i + 1))
    done
    [ "$delay" -gt 960 ] && delay=960

    local elapsed=$((now - last))
    if [ "$elapsed" -ge "$delay" ]; then
        echo "$now" > "$ts_file"
        return 0  # OK to attempt
    fi

    return 1  # Too soon, skip
}

# Reset counts daily
reset_daily_counts() {
    local today=$(date +%Y%m%d)
    local last_reset=$(cat "$STATE_DIR/last_reset" 2>/dev/null || echo 0)
    if [ "$today" != "$last_reset" ]; then
        rm -f "$STATE_DIR"/*_recovery_count
        rm -f "$STATE_DIR"/*_last_recovery
        rm -f "$STATE_DIR"/escalation_count
        echo "$today" > "$STATE_DIR/last_reset"
        log "INFO: Daily recovery count reset"
    fi
}

# Check if AP interface is up and working
check_ap_interface() {
    local ap_if="${AP_IF:-wlan1}"

    # Check interface exists and has IP
    if ! ip addr show "$ap_if" 2>/dev/null | grep -q "192.168.4.1"; then
        log "WARN: AP interface $ap_if missing or wrong IP"
        return 1
    fi

    return 0
}

# Check if hostapd is running
check_hostapd() {
    if ! sctl is-active --quiet hostapd; then
        log "WARN: hostapd is not running"
        return 1
    fi

    # Check if AP is actually broadcasting
    if ! iw dev 2>/dev/null | grep -q "type AP"; then
        log "WARN: No AP mode interface detected"
        return 1
    fi

    return 0
}

# Check if dnsmasq is running and functional
check_dnsmasq() {
    if ! sctl is-active --quiet dnsmasq; then
        log "WARN: dnsmasq is not running"
        return 1
    fi

    # Every 5th minute, verify DNS actually resolves (only if upstream is available)
    if [ $(( $(date +%M) % 5 )) -eq 0 ] && check_upstream; then
        if ! timeout 3 nslookup google.com 192.168.4.1 >/dev/null 2>&1; then
            log "WARN: dnsmasq running but DNS resolution failed"
            return 1
        fi
    fi

    return 0
}

# Check if captive portal is running
check_portal() {
    if ! sctl is-active --quiet captive-portal; then
        log "WARN: captive-portal is not running"
        return 1
    fi

    # Check if port 80 is listening
    if ! ss -tlnp 2>/dev/null | grep -q ":80 "; then
        log "WARN: Nothing listening on port 80"
        return 1
    fi

    return 0
}

# Check if we have upstream connectivity (WiFi or Ethernet)
check_upstream() {
    local has_upstream=0

    # Check wlan0
    if ip link show wlan0 2>/dev/null | grep -q "state UP"; then
        if ip addr show wlan0 2>/dev/null | grep -q "inet "; then
            has_upstream=1
        fi
    fi

    # Check eth0
    if ip link show eth0 2>/dev/null | grep -q "state UP"; then
        if ip addr show eth0 2>/dev/null | grep -q "inet "; then
            has_upstream=1
        fi
    fi

    if [ "$has_upstream" -eq 0 ]; then
        return 1
    fi

    # Verify actual connectivity: ping 2 out of 3 DNS servers
    local success=0
    for target in 8.8.8.8 1.1.1.1 9.9.9.9; do
        if timeout 2 ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
            success=$((success + 1))
        fi
    done

    if [ "$success" -lt 2 ]; then
        log "WARN: Upstream interface up but connectivity weak ($success/3 pings succeeded)"
        return 1
    fi

    return 0
}

# Check VPN status
check_vpn() {
    # Check NordVPN
    if command -v nordvpn &>/dev/null; then
        if timeout 10 nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
            return 0
        fi
    fi

    # Check WireGuard
    if ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "UP"; then
        return 0
    fi

    return 1
}

# Check VPN health - verifies tunnel is actually passing traffic
check_vpn_health() {
    if ! check_vpn; then
        return 1
    fi

    # Ping through VPN to verify tunnel works
    # Use a well-known IP, short timeout
    if ! timeout 5 ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log "WARN: VPN connected but tunnel not passing traffic"
        return 1
    fi

    return 0
}

# Recover VPN connection
recover_vpn() {
    local count=$(increment_recovery_count "vpn")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many VPN recovery attempts, skipping"
        return 1
    fi

    if ! should_attempt_recovery "vpn"; then
        log "INFO: VPN recovery backoff active, skipping (attempt $count)"
        return 1
    fi

    log "INFO: Attempting VPN recovery (attempt $count)"

    # Disconnect first
    if command -v nordvpn &>/dev/null; then
        timeout 10 nordvpn disconnect >/dev/null 2>&1
    fi
    sleep 2

    # Reconnect using VPN start command
    if [ -x "$VPN_START_CMD" ]; then
        if "$VPN_START_CMD" >/dev/null 2>&1; then
            sleep 5
            if check_vpn_health; then
                log "INFO: VPN recovery successful"
                reset_recovery_count "vpn"
                return 0
            else
                log "ERROR: VPN reconnected but health check failed"
                return 1
            fi
        else
            log "ERROR: VPN start command failed"
            return 1
        fi
    else
        # Fallback: try nordvpn connect directly
        if command -v nordvpn &>/dev/null; then
            local state_file="$STATE_DIR/portal-state.json"
            local server=""
            if [ -f "$state_file" ]; then
                server=$(STATE_FILE="$state_file" python3 -c "import json,os; print(json.load(open(os.environ['STATE_FILE'])).get('last_vpn_server',''))" 2>/dev/null || true)
            fi

            local cmd="nordvpn connect"
            [ -n "$server" ] && cmd="nordvpn connect $server"

            if timeout 30 $cmd >/dev/null 2>&1; then
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
    fi
}

# Recover WiFi connection
recover_wifi() {
    local count=$(increment_recovery_count "wifi")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many WiFi recovery attempts, skipping"
        return 1
    fi

    if ! should_attempt_recovery "wifi"; then
        log "INFO: WiFi recovery backoff active, skipping (attempt $count)"
        return 1
    fi

    local state_file="$STATE_DIR/portal-state.json"
    local ssid=""
    if [ -f "$state_file" ]; then
        ssid=$(STATE_FILE="$state_file" python3 -c "import json,os; print(json.load(open(os.environ['STATE_FILE'])).get('last_wifi_ssid',''))" 2>/dev/null || true)
    fi

    if [ -z "$ssid" ]; then
        log "WARN: No last WiFi SSID found for recovery"
        return 1
    fi

    log "INFO: Attempting WiFi recovery for '$ssid' (attempt $count)"

    # Try to bring up the last known connection
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

    # Fallback: try by SSID name
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
    current_upstream="$(get_best_upstream || true)"
    if [ -z "$current_upstream" ]; then
        return 0
    fi

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

# Recovery functions
recover_ap_interface() {
    local ap_if="${AP_IF:-wlan1}"

    if ! should_attempt_recovery "ap_interface"; then
        log "INFO: AP interface recovery backoff active, skipping"
        return 1
    fi

    local count=$(increment_recovery_count "ap_interface")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many AP interface recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting AP interface recovery (attempt $count)"

    # Unblock WiFi
    rfkill unblock wifi 2>/dev/null || true

    # Bring up interface
    ip link set "$ap_if" up 2>/dev/null || true
    sleep 1

    # Set IP
    ip addr flush dev "$ap_if" 2>/dev/null || true
    ip addr add 192.168.4.1/24 dev "$ap_if" 2>/dev/null || true

    log "INFO: AP interface recovery completed"
    return 0
}

recover_hostapd() {
    if ! should_attempt_recovery "hostapd"; then
        log "INFO: hostapd recovery backoff active, skipping"
        return 1
    fi

    local count=$(increment_recovery_count "hostapd")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many hostapd recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting hostapd recovery (attempt $count)"

    # Stop cleanly first
    sctl stop hostapd || true
    sleep 1

    # Make sure interface is ready
    recover_ap_interface
    sleep 1

    # Start hostapd
    sctl start hostapd
    sleep 2

    if sctl is-active --quiet hostapd; then
        log "INFO: hostapd recovery successful"
        reset_recovery_count "hostapd"
        return 0
    else
        log "ERROR: hostapd recovery failed"
        return 1
    fi
}

recover_dnsmasq() {
    if ! should_attempt_recovery "dnsmasq"; then
        log "INFO: dnsmasq recovery backoff active, skipping"
        return 1
    fi

    local count=$(increment_recovery_count "dnsmasq")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many dnsmasq recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting dnsmasq recovery (attempt $count)"

    sctl restart dnsmasq
    sleep 1

    if sctl is-active --quiet dnsmasq; then
        log "INFO: dnsmasq recovery successful"
        reset_recovery_count "dnsmasq"
        return 0
    else
        log "ERROR: dnsmasq recovery failed"
        return 1
    fi
}

recover_portal() {
    if ! should_attempt_recovery "portal"; then
        log "INFO: portal recovery backoff active, skipping"
        return 1
    fi

    local count=$(increment_recovery_count "portal")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many portal recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting portal recovery (attempt $count)"

    # Kill any stuck processes
    pkill -f captive-portal-server.py 2>/dev/null || true
    sleep 1

    sctl restart captive-portal
    sleep 2

    if sctl is-active --quiet captive-portal; then
        log "INFO: Portal recovery successful"
        reset_recovery_count "portal"
        return 0
    else
        log "ERROR: Portal recovery failed"
        return 1
    fi
}

# Reinforce power save off on AP interface to prevent long-running disconnects
reinforce_power_save_off() {
    local ap_if="${AP_IF:-wlan1}"
    iw dev "$ap_if" set power_save off 2>/dev/null || true
}

# Escalation: Full reset when normal recovery exhausted
# This is a more aggressive recovery that reloads the wireless driver
escalate_ap_recovery() {
    local ap_if="${AP_IF:-wlan1}"

    # Check escalation count
    local esc_count=$(cat "$STATE_DIR/escalation_count" 2>/dev/null || echo 0)
    if [ "$esc_count" -ge "$MAX_ESCALATIONS" ]; then
        log "CRITICAL: Escalation limit ($MAX_ESCALATIONS) reached. Manual intervention required."
        return 1
    fi
    esc_count=$((esc_count + 1))
    echo "$esc_count" > "$STATE_DIR/escalation_count"

    log "WARN: Escalating to full AP recovery (escalation $esc_count/$MAX_ESCALATIONS) - reloading wireless subsystem"

    # Stop all AP-related services
    sctl stop hostapd || true
    sctl stop dnsmasq || true
    sleep 2

    # Unblock and reset wireless
    rfkill unblock wifi 2>/dev/null || true

    # Bring down and up the interface
    ip link set "$ap_if" down 2>/dev/null || true
    sleep 2
    ip link set "$ap_if" up 2>/dev/null || true
    sleep 2

    # Re-apply power save off
    iw dev "$ap_if" set power_save off 2>/dev/null || true

    # Set IP
    ip addr flush dev "$ap_if" 2>/dev/null || true
    ip addr add 192.168.4.1/24 dev "$ap_if" 2>/dev/null || true
    sleep 1

    # Restart services
    sctl start hostapd
    sleep 3
    sctl start dnsmasq
    sleep 1

    # Verify - only reset per-service counters on SUCCESS
    if sctl is-active --quiet hostapd && iw dev 2>/dev/null | grep -q "type AP"; then
        log "INFO: Full AP recovery successful - AP is broadcasting"
        reset_recovery_count "ap_interface"
        reset_recovery_count "hostapd"
        reset_recovery_count "dnsmasq"
        return 0
    else
        log "ERROR: Full AP recovery failed - manual intervention may be needed"
        return 1
    fi
}

# Ensure SSH is always accessible
ensure_ssh_access() {
    # Make sure SSH is running
    if ! sctl is-active --quiet ssh; then
        log "WARN: SSH not running, starting..."
        sctl start ssh
    fi

    # Ensure iptables allows SSH on all interfaces (delete-before-insert to prevent duplication)
    ipt -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    ipt -I INPUT 1 -p tcp --dport 22 -j ACCEPT
}

# Ensure management access is never blocked
ensure_management_access() {
    local ap_if="${AP_IF:-wlan1}"

    # Always allow SSH
    ensure_ssh_access

    # Always allow AP interface access to portal (delete-before-insert)
    ipt -D INPUT -i "$ap_if" -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    ipt -I INPUT 2 -i "$ap_if" -p tcp --dport 80 -j ACCEPT

    # Always allow DHCP on AP (delete-before-insert)
    ipt -D INPUT -i "$ap_if" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
    ipt -I INPUT 3 -i "$ap_if" -p udp --dport 67 -j ACCEPT

    # Always allow DNS on AP (delete-before-insert)
    ipt -D INPUT -i "$ap_if" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    ipt -I INPUT 4 -i "$ap_if" -p udp --dport 53 -j ACCEPT
}

# Main watchdog loop
main() {
    log "INFO: Watchdog check starting"

    reset_daily_counts

    local issues_found=0

    # Always ensure management access first (highest priority)
    ensure_management_access

    # Reinforce power save off every cycle to prevent driver re-enabling it
    reinforce_power_save_off

    # Check and recover AP interface
    if ! check_ap_interface; then
        recover_ap_interface
        issues_found=1
    fi

    # Check and recover hostapd
    if ! check_hostapd; then
        if ! recover_hostapd; then
            # Normal recovery failed (hit max attempts) - escalate
            local hostapd_count=$(get_recovery_count "hostapd")
            if [ "$hostapd_count" -ge 5 ]; then
                log "WARN: Normal hostapd recovery exhausted, escalating..."
                escalate_ap_recovery
            fi
        fi
        issues_found=1
    fi

    # Check and recover dnsmasq
    if ! check_dnsmasq; then
        recover_dnsmasq
        issues_found=1
    fi

    # Check and recover portal
    if ! check_portal; then
        recover_portal
        issues_found=1
    fi

    # Check WiFi - reconnect if dropped and we have a saved SSID
    local upstream_if="${UPSTREAM_IF:-wlan0}"
    local wifi_up=0
    if ip link show "$upstream_if" 2>/dev/null | grep -q "state UP"; then
        if ip addr show "$upstream_if" 2>/dev/null | grep -q "inet "; then
            wifi_up=1
        fi
    fi

    if [ "$wifi_up" -eq 0 ]; then
        local state_file="$STATE_DIR/portal-state.json"
        if [ -f "$state_file" ]; then
            local has_ssid=$(STATE_FILE="$state_file" python3 -c "import json,os; s=json.load(open(os.environ['STATE_FILE'])); print('yes' if s.get('last_wifi_ssid') else 'no')" 2>/dev/null || echo "no")
            if [ "$has_ssid" = "yes" ]; then
                log "WARN: WiFi disconnected but saved SSID exists, attempting recovery..."
                recover_wifi
                issues_found=1
            fi
        fi
    fi

    # Check VPN - recover if it should be active but isn't
    if [ -f "$STATE_DIR/vpn_should_be_active" ]; then
        if ! check_vpn_health; then
            log "WARN: VPN should be active but is down/unhealthy, attempting recovery..."
            recover_vpn
            issues_found=1
        fi
    fi

    # Restart VPN if upstream changes while connected
    maybe_restart_vpn_on_upstream_change

    # Log summary
    if [ "$issues_found" -eq 0 ]; then
        # Only log healthy status every 10 minutes to reduce noise
        if [ $(( $(date +%M) % 10 )) -eq 0 ]; then
            log "INFO: All services healthy"
        fi
    fi

    # Record last successful check
    date +%s > "$STATE_DIR/last_watchdog_check"
}

main "$@"

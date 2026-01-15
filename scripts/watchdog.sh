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

# Ensure state directory exists
mkdir -p "$STATE_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
    # Rotate log if too large
    if [ -f "$LOGFILE" ] && [ $(stat -f%z "$LOGFILE" 2>/dev/null || stat -c%s "$LOGFILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
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

# Reset counts daily
reset_daily_counts() {
    local today=$(date +%Y%m%d)
    local last_reset=$(cat "$STATE_DIR/last_reset" 2>/dev/null || echo 0)
    if [ "$today" != "$last_reset" ]; then
        rm -f "$STATE_DIR"/*_recovery_count
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
    if ! systemctl is-active --quiet hostapd; then
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

# Check if dnsmasq is running
check_dnsmasq() {
    if ! systemctl is-active --quiet dnsmasq; then
        log "WARN: dnsmasq is not running"
        return 1
    fi
    return 0
}

# Check if captive portal is running
check_portal() {
    if ! systemctl is-active --quiet captive-portal; then
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

    return $((1 - has_upstream))
}

# Check VPN status
check_vpn() {
    # Check NordVPN
    if command -v nordvpn &>/dev/null; then
        if nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
            return 0
        fi
    fi

    # Check WireGuard
    if ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "UP"; then
        return 0
    fi

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
    local count=$(increment_recovery_count "hostapd")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many hostapd recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting hostapd recovery (attempt $count)"

    # Stop cleanly first
    systemctl stop hostapd 2>/dev/null || true
    sleep 1

    # Make sure interface is ready
    recover_ap_interface
    sleep 1

    # Start hostapd
    systemctl start hostapd
    sleep 2

    if systemctl is-active --quiet hostapd; then
        log "INFO: hostapd recovery successful"
        reset_recovery_count "hostapd"
        return 0
    else
        log "ERROR: hostapd recovery failed"
        return 1
    fi
}

recover_dnsmasq() {
    local count=$(increment_recovery_count "dnsmasq")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many dnsmasq recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting dnsmasq recovery (attempt $count)"

    systemctl restart dnsmasq
    sleep 1

    if systemctl is-active --quiet dnsmasq; then
        log "INFO: dnsmasq recovery successful"
        reset_recovery_count "dnsmasq"
        return 0
    else
        log "ERROR: dnsmasq recovery failed"
        return 1
    fi
}

recover_portal() {
    local count=$(increment_recovery_count "portal")

    if [ "$count" -gt 5 ]; then
        log "ERROR: Too many portal recovery attempts, skipping"
        return 1
    fi

    log "INFO: Attempting portal recovery (attempt $count)"

    # Kill any stuck processes
    pkill -f captive-portal-server.py 2>/dev/null || true
    sleep 1

    systemctl restart captive-portal
    sleep 2

    if systemctl is-active --quiet captive-portal; then
        log "INFO: Portal recovery successful"
        reset_recovery_count "portal"
        return 0
    else
        log "ERROR: Portal recovery failed"
        return 1
    fi
}

# Ensure SSH is always accessible
ensure_ssh_access() {
    # Make sure SSH is running
    if ! systemctl is-active --quiet ssh; then
        log "WARN: SSH not running, starting..."
        systemctl start ssh
    fi

    # Ensure iptables allows SSH on all interfaces
    # This is a safety net - add rules if missing
    if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
        log "INFO: Added SSH allow rule to iptables"
    fi
}

# Ensure management access is never blocked
ensure_management_access() {
    local ap_if="${AP_IF:-wlan1}"

    # Always allow SSH
    ensure_ssh_access

    # Always allow AP interface access to portal
    if ! iptables -C INPUT -i "$ap_if" -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 2 -i "$ap_if" -p tcp --dport 80 -j ACCEPT
        log "INFO: Added portal HTTP rule"
    fi

    # Always allow DHCP on AP
    if ! iptables -C INPUT -i "$ap_if" -p udp --dport 67 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 3 -i "$ap_if" -p udp --dport 67 -j ACCEPT
        log "INFO: Added DHCP rule"
    fi

    # Always allow DNS on AP
    if ! iptables -C INPUT -i "$ap_if" -p udp --dport 53 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 4 -i "$ap_if" -p udp --dport 53 -j ACCEPT
        log "INFO: Added DNS rule"
    fi
}

# Main watchdog loop
main() {
    log "INFO: Watchdog check starting"

    reset_daily_counts

    local issues_found=0

    # Always ensure management access first (highest priority)
    ensure_management_access

    # Check and recover AP interface
    if ! check_ap_interface; then
        recover_ap_interface
        issues_found=1
    fi

    # Check and recover hostapd
    if ! check_hostapd; then
        recover_hostapd
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

#!/bin/bash
# Stop VPN in a provider-aware way.

set -e

VPN_MODE="${VPN_MODE:-auto}"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if [ "$VPN_MODE" = "auto" ]; then
    if command_exists nordvpn; then
        VPN_MODE="nordvpn"
    else
        VPN_MODE="wireguard"
    fi
fi

if [ "$VPN_MODE" = "nordvpn" ]; then
    if command_exists nordvpn; then
        nordvpn disconnect 2>/dev/null || true
    fi
else
    wg-quick down "$VPN_INTERFACE" 2>/dev/null || true
fi

# Restore firewall so AP clients aren't locked out after VPN stops
# Switch to internet mode (NAT without VPN) or fall back to permissive
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x /usr/local/bin/iptables-internet-mode.sh ]; then
    /usr/local/bin/iptables-internet-mode.sh || true
elif [ -x "$SCRIPT_DIR/iptables-internet-mode.sh" ]; then
    "$SCRIPT_DIR/iptables-internet-mode.sh" || true
fi

# Safety net: if policies are still DROP, force ACCEPT to prevent lockout
if iptables -L INPUT 2>/dev/null | head -1 | grep -q "DROP"; then
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -t nat -F
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
fi

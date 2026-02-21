#!/bin/bash
# Internet Mode - Allow forwarding through upstream WITHOUT VPN
# Used after WiFi connects but before VPN is enabled
# WARNING: Traffic is NOT encrypted in this mode!
# SAFETY: SSH is always allowed on ALL interfaces to prevent lockout
# Uses iptables-restore for atomic rule loading (no traffic gap)

AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"
AP_SUBNET="192.168.4.0/24"
AP_IP="192.168.4.1"

# Source HaLow config if available
[ -f /etc/default/vpn-ap ] && . /etc/default/vpn-ap
HALOW_IF="${HALOW_INTERFACE:-wlan2}"

# Auto-detect upstream interface (including HaLow)
if ip link show eth0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_IF="eth0"
elif ip link show wlan0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_IF="wlan0"
elif ip link show "$HALOW_IF" 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_IF="$HALOW_IF"
    echo "  Note: Using HaLow ($HALOW_IF) as upstream"
fi

echo "Setting up internet mode (no VPN protection)..."
echo "  AP Interface: $AP_IF"
echo "  Upstream Interface: $UPSTREAM_IF"

# Load all rules atomically via iptables-restore
iptables-restore <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Allow loopback
-A INPUT -i lo -j ACCEPT

# Allow established/related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === CRITICAL: SSH on ALL interfaces (prevent lockout) ===
-A INPUT -p tcp --dport 22 -j ACCEPT

# === AP Interface - Allow portal services ===

# DHCP server
-A INPUT -i $AP_IF -p udp --dport 67 -j ACCEPT

# DNS server
-A INPUT -i $AP_IF -p udp --dport 53 -j ACCEPT
-A INPUT -i $AP_IF -p tcp --dport 53 -j ACCEPT

# HTTP (captive portal web interface)
-A INPUT -i $AP_IF -p tcp --dport 80 -j ACCEPT

# Ping
-A INPUT -i $AP_IF -p icmp --icmp-type echo-request -j ACCEPT

# DHCP client (to get/maintain IP from hotel)
-A INPUT -i $UPSTREAM_IF -p udp --sport 67:68 --dport 67:68 -j ACCEPT

# === FORWARDING - Route AP clients through upstream ===

# Forward AP traffic to upstream (internet without VPN)
-A FORWARD -i $AP_IF -o $UPSTREAM_IF -j ACCEPT
-A FORWARD -i $UPSTREAM_IF -o $AP_IF -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# NAT AP clients through upstream
-A POSTROUTING -s $AP_SUBNET -o $UPSTREAM_IF -j MASQUERADE

COMMIT
RULES

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "Internet mode active - traffic forwarded through upstream (unencrypted!)"
echo "Connect VPN for protected browsing."

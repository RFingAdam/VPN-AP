#!/bin/bash
# Internet Mode - Allow forwarding through upstream WITHOUT VPN
# Used after WiFi connects but before VPN is enabled
# WARNING: Traffic is NOT encrypted in this mode!

AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"
AP_SUBNET="192.168.4.0/24"
AP_IP="192.168.4.1"

# Auto-detect upstream interface
if ip link show eth0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_IF="eth0"
elif ip link show wlan0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_IF="wlan0"
fi

echo "Setting up internet mode (no VPN protection)..."
echo "  AP Interface: $AP_IF"
echo "  Upstream Interface: $UPSTREAM_IF"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -X 2>/dev/null || true

# Default policies - DROP by default for safety
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === AP Interface - Allow portal services ===

# DHCP server
iptables -A INPUT -i $AP_IF -p udp --dport 67 -j ACCEPT

# DNS server
iptables -A INPUT -i $AP_IF -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i $AP_IF -p tcp --dport 53 -j ACCEPT

# HTTP (captive portal web interface)
iptables -A INPUT -i $AP_IF -p tcp --dport 80 -j ACCEPT

# SSH (for management)
iptables -A INPUT -i $AP_IF -p tcp --dport 22 -j ACCEPT

# Ping
iptables -A INPUT -i $AP_IF -p icmp --icmp-type echo-request -j ACCEPT

# === Upstream Interface ===

# SSH on upstream (if needed from local network)
iptables -A INPUT -i $UPSTREAM_IF -p tcp --dport 22 -j ACCEPT

# DHCP client (to get/maintain IP from hotel)
iptables -A INPUT -i $UPSTREAM_IF -p udp --sport 67:68 --dport 67:68 -j ACCEPT

# === FORWARDING - Route AP clients through upstream ===

# Forward AP traffic to upstream (internet without VPN)
iptables -A FORWARD -i $AP_IF -o $UPSTREAM_IF -j ACCEPT
iptables -A FORWARD -i $UPSTREAM_IF -o $AP_IF -j ACCEPT

# NAT AP clients through upstream
iptables -t nat -A POSTROUTING -s $AP_SUBNET -o $UPSTREAM_IF -j MASQUERADE

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "Internet mode active - traffic forwarded through upstream (unencrypted!)"
echo "Connect VPN for protected browsing."

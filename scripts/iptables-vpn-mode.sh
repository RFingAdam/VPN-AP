#!/bin/bash
# VPN Mode - Kill switch that only allows traffic through VPN
# Called after VPN connects successfully
# SAFETY: SSH is always allowed on ALL interfaces to prevent lockout

VPN_IF="${VPN_IF:-nordlynx}"
AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"
AP_SUBNET="192.168.4.0/24"

# Auto-detect VPN interface if nordlynx doesn't exist
if ! ip link show $VPN_IF &>/dev/null; then
    VPN_IF=$(ip link show | grep -oE "nordlynx[0-9]*|nordtun[0-9]*" | head -1)
    if [ -z "$VPN_IF" ]; then
        echo "ERROR: No VPN interface found! Is VPN connected?"
        exit 1
    fi
fi

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

echo "Setting up VPN kill switch mode..."
echo "  VPN Interface: $VPN_IF"
echo "  AP Interface: $AP_IF"
echo "  Upstream Interface: $UPSTREAM_IF"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -X 2>/dev/null || true

# Default policies - DROP everything (kill switch)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === CRITICAL: SSH on ALL interfaces (prevent lockout) ===
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 22 -j ACCEPT

# DHCP server on AP interface
iptables -A INPUT -i $AP_IF -p udp --dport 67 -j ACCEPT
iptables -A OUTPUT -o $AP_IF -p udp --sport 67 -j ACCEPT

# DNS server on AP interface (dnsmasq)
iptables -A INPUT -i $AP_IF -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i $AP_IF -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -o $AP_IF -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -o $AP_IF -p tcp --sport 53 -j ACCEPT

# HTTP on AP interface (captive portal status page)
iptables -A INPUT -i $AP_IF -p tcp --dport 80 -j ACCEPT

# Ping on AP interface
iptables -A INPUT -i $AP_IF -p icmp --icmp-type echo-request -j ACCEPT
iptables -A OUTPUT -o $AP_IF -p icmp --icmp-type echo-reply -j ACCEPT

# === UPSTREAM RULES (minimal - only VPN tunnel) ===

# DHCP client (to maintain hotel IP)
iptables -A OUTPUT -o $UPSTREAM_IF -p udp --dport 67:68 --sport 67:68 -j ACCEPT
iptables -A INPUT -i $UPSTREAM_IF -p udp --sport 67:68 --dport 67:68 -j ACCEPT

# NordVPN/WireGuard tunnel establishment (UDP)
iptables -A OUTPUT -o $UPSTREAM_IF -p udp -m conntrack --ctstate NEW -j ACCEPT

# === VPN INTERFACE RULES ===

# Allow ALL traffic through VPN tunnel
iptables -A INPUT -i $VPN_IF -j ACCEPT
iptables -A OUTPUT -o $VPN_IF -j ACCEPT

# === FORWARDING RULES (AP clients through VPN ONLY) ===

# Forward AP traffic ONLY through VPN (kill switch - no direct upstream)
iptables -A FORWARD -i $AP_IF -o $VPN_IF -j ACCEPT
iptables -A FORWARD -i $VPN_IF -o $AP_IF -j ACCEPT

# NAT AP clients through VPN
iptables -t nat -A POSTROUTING -s $AP_SUBNET -o $VPN_IF -j MASQUERADE

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "VPN kill switch active - all traffic routed through VPN"
echo "If VPN disconnects, internet will stop (kill switch)"

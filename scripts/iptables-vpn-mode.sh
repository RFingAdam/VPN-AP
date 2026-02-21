#!/bin/bash
# VPN Mode - Kill switch that only allows traffic through VPN
# Called after VPN connects successfully
# SAFETY: SSH is always allowed on ALL interfaces to prevent lockout
# Uses iptables-restore for atomic rule loading (no traffic gap)

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

# Load all rules atomically via iptables-restore
iptables-restore <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# Allow loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === CRITICAL: SSH on ALL interfaces (prevent lockout) ===
-A INPUT -p tcp --dport 22 -j ACCEPT
-A OUTPUT -p tcp --sport 22 -j ACCEPT

# DHCP server on AP interface
-A INPUT -i $AP_IF -p udp --dport 67 -j ACCEPT
-A OUTPUT -o $AP_IF -p udp --sport 67 -j ACCEPT

# DNS server on AP interface (dnsmasq)
-A INPUT -i $AP_IF -p udp --dport 53 -j ACCEPT
-A INPUT -i $AP_IF -p tcp --dport 53 -j ACCEPT
-A OUTPUT -o $AP_IF -p udp --sport 53 -j ACCEPT
-A OUTPUT -o $AP_IF -p tcp --sport 53 -j ACCEPT

# HTTP on AP interface (captive portal status page)
-A INPUT -i $AP_IF -p tcp --dport 80 -j ACCEPT

# Ping on AP interface
-A INPUT -i $AP_IF -p icmp --icmp-type echo-request -j ACCEPT
-A OUTPUT -o $AP_IF -p icmp --icmp-type echo-reply -j ACCEPT

# === UPSTREAM RULES (minimal - only VPN tunnel) ===

# DHCP client (to maintain hotel IP)
-A OUTPUT -o $UPSTREAM_IF -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -i $UPSTREAM_IF -p udp --sport 67:68 --dport 67:68 -j ACCEPT

# NordVPN/WireGuard tunnel establishment (UDP)
-A OUTPUT -o $UPSTREAM_IF -p udp -m conntrack --ctstate NEW -j ACCEPT

# === VPN INTERFACE RULES ===

# Allow ALL traffic through VPN tunnel
-A INPUT -i $VPN_IF -j ACCEPT
-A OUTPUT -o $VPN_IF -j ACCEPT

# === FORWARDING RULES (AP clients through VPN ONLY) ===

# Forward AP traffic ONLY through VPN (kill switch - no direct upstream)
-A FORWARD -i $AP_IF -o $VPN_IF -j ACCEPT
-A FORWARD -i $VPN_IF -o $AP_IF -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# NAT AP clients through VPN
-A POSTROUTING -s $AP_SUBNET -o $VPN_IF -j MASQUERADE

COMMIT
RULES

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "VPN kill switch active - all traffic routed through VPN"
echo "If VPN disconnects, internet will stop (kill switch)"

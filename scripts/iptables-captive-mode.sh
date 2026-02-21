#!/bin/bash
# Captive Portal Mode - Restrictive iptables that only allows portal access
# Used on boot before VPN is connected
# SAFETY: SSH is always allowed on ALL interfaces to prevent lockout
# Uses iptables-restore for atomic rule loading (no traffic gap)

AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"
AP_IP="192.168.4.1"
AP_SUBNET="192.168.4.0/24"

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
fi

echo "Setting up captive portal mode (restrictive)..."
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

# Allow established connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === CRITICAL: SSH on ALL interfaces (prevent lockout) ===
-A INPUT -p tcp --dport 22 -j ACCEPT
-A OUTPUT -p tcp --sport 22 -j ACCEPT

# === AP Interface - Allow portal services ===

# DHCP server
-A INPUT -i $AP_IF -p udp --dport 67 -j ACCEPT
-A OUTPUT -o $AP_IF -p udp --sport 67 -j ACCEPT

# DNS (will redirect to portal)
-A INPUT -i $AP_IF -p udp --dport 53 -j ACCEPT
-A INPUT -i $AP_IF -p tcp --dport 53 -j ACCEPT
-A OUTPUT -o $AP_IF -p udp --sport 53 -j ACCEPT
-A OUTPUT -o $AP_IF -p tcp --sport 53 -j ACCEPT

# HTTP (captive portal web interface)
-A INPUT -i $AP_IF -p tcp --dport 80 -j ACCEPT
-A OUTPUT -o $AP_IF -p tcp --sport 80 -j ACCEPT

# Ping
-A INPUT -i $AP_IF -p icmp --icmp-type echo-request -j ACCEPT
-A OUTPUT -o $AP_IF -p icmp --icmp-type echo-reply -j ACCEPT

# === Upstream - Only allow what Pi needs to set up connection ===

# Allow DHCP client (to get IP from hotel)
-A OUTPUT -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -p udp --sport 67:68 --dport 67:68 -j ACCEPT

# Allow DNS (for Pi to resolve VPN server, etc.)
-A OUTPUT -p udp --dport 53 -j ACCEPT
-A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow HTTP/HTTPS (for Pi to connect to hotel captive portal and NordVPN API)
-A OUTPUT -p tcp --dport 80 -j ACCEPT
-A OUTPUT -p tcp --dport 443 -j ACCEPT

# Allow NordVPN connection (WireGuard UDP)
-A OUTPUT -p udp -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# Redirect all HTTP from AP clients to captive portal (for portal detection)
-A PREROUTING -i $AP_IF -p tcp --dport 80 -j DNAT --to-destination $AP_IP:80

COMMIT
RULES

echo "Captive portal mode active - no internet forwarding until VPN connects"

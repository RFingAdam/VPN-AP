#!/bin/bash
# Start VPN and configure routing
# Supports both NordVPN CLI and WireGuard
# Usage: sudo ./start-vpn.sh [--wireguard]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Configuration
AP_INTERFACE="${AP_INTERFACE:-wlan1}"
AP_SUBNET="192.168.4.0/24"
USE_WIREGUARD=false

# Parse arguments
if [[ "$1" == "--wireguard" ]]; then
    USE_WIREGUARD=true
fi

echo -e "${GREEN}Starting VPN and configuring routing...${NC}"

# Detect upstream interface
if ip link show eth0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_INTERFACE="eth0"
    echo "Using Ethernet (eth0) as upstream"
elif ip link show wlan0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM_INTERFACE="wlan0"
    echo "Using WiFi (wlan0) as upstream"
else
    echo -e "${YELLOW}Warning: No upstream interface detected as UP${NC}"
    UPSTREAM_INTERFACE="wlan0"
fi

# Detect VPN method
if [[ "$USE_WIREGUARD" == true ]]; then
    VPN_METHOD="wireguard"
elif command -v nordvpn &> /dev/null; then
    VPN_METHOD="nordvpn"
elif [ -f /etc/wireguard/wg0.conf ]; then
    VPN_METHOD="wireguard"
else
    echo -e "${RED}Error: No VPN method available!${NC}"
    echo "Install NordVPN CLI or configure WireGuard at /etc/wireguard/wg0.conf"
    exit 1
fi

echo "Using VPN method: $VPN_METHOD"

if [[ "$VPN_METHOD" == "nordvpn" ]]; then
    # ============================================
    # NordVPN CLI Method
    # ============================================

    # Ensure NordVPN settings are correct for AP routing
    echo "Configuring NordVPN settings..."
    nordvpn set lan-discovery enabled 2>/dev/null || true
    nordvpn allowlist add port 22 2>/dev/null || true

    # Disconnect if already connected
    nordvpn disconnect 2>/dev/null || true
    sleep 1

    # Connect to NordVPN
    echo "Connecting to NordVPN..."
    nordvpn connect

    # Wait for connection
    sleep 3

    # Verify connection
    if nordvpn status | grep -q "Status: Connected"; then
        echo -e "${GREEN}NordVPN connected successfully${NC}"
    else
        echo -e "${RED}Failed to connect to NordVPN${NC}"
        nordvpn status
        exit 1
    fi

    # Get VPN interface (nordlynx for NordLynx/WireGuard)
    VPN_INTERFACE=$(ip link show | grep -oE "nordlynx[0-9]*|nordtun[0-9]*" | head -1)
    if [ -z "$VPN_INTERFACE" ]; then
        echo -e "${YELLOW}Could not detect NordVPN interface, using nordlynx${NC}"
        VPN_INTERFACE="nordlynx"
    fi

else
    # ============================================
    # WireGuard Method
    # ============================================
    VPN_INTERFACE="wg0"

    if [ ! -f /etc/wireguard/wg0.conf ]; then
        echo -e "${RED}Error: /etc/wireguard/wg0.conf not found!${NC}"
        echo "Please configure WireGuard or install NordVPN CLI"
        exit 1
    fi

    # Check for placeholder values
    if grep -q "YOUR_NORDVPN_PRIVATE_KEY_HERE" /etc/wireguard/wg0.conf; then
        echo -e "${RED}Error: WireGuard config still has placeholder values!${NC}"
        exit 1
    fi

    # Stop VPN if running
    wg-quick down wg0 2>/dev/null || true

    # Start WireGuard VPN
    echo "Starting WireGuard..."
    wg-quick up wg0

    if ip link show wg0 2>/dev/null | grep -q "UP"; then
        echo -e "${GREEN}WireGuard started successfully${NC}"
    else
        echo -e "${RED}Failed to start WireGuard${NC}"
        exit 1
    fi
fi

# ============================================
# Configure iptables for AP traffic forwarding
# ============================================
echo "Configuring firewall rules for AP traffic..."

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Set up NAT for AP clients through VPN
# (NordVPN handles its own firewall, we just need to forward AP traffic)

if [[ "$VPN_METHOD" == "nordvpn" ]]; then
    # NordVPN manages its own firewall, we just add forwarding rules
    # Clear any existing AP-related rules
    iptables -t nat -D POSTROUTING -s $AP_SUBNET -o $VPN_INTERFACE -j MASQUERADE 2>/dev/null || true

    # Add NAT for AP clients
    iptables -t nat -A POSTROUTING -s $AP_SUBNET -o $VPN_INTERFACE -j MASQUERADE

    # Allow forwarding between AP and VPN
    iptables -I FORWARD 1 -i $AP_INTERFACE -o $VPN_INTERFACE -j ACCEPT
    iptables -I FORWARD 2 -i $VPN_INTERFACE -o $AP_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
else
    # WireGuard: Set up full iptables rules with kill switch
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X 2>/dev/null || true

    # Default policies - DROP (kill switch)
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow SSH from AP clients and upstream (for management)
    iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -i $UPSTREAM_INTERFACE -p tcp --dport 22 -j ACCEPT

    # Allow DHCP/DNS on AP interface
    iptables -A INPUT -i $AP_INTERFACE -p udp --dport 67 -j ACCEPT
    iptables -A INPUT -i $AP_INTERFACE -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -i $AP_INTERFACE -p icmp --icmp-type echo-request -j ACCEPT

    # Allow WireGuard to upstream
    iptables -A OUTPUT -o $UPSTREAM_INTERFACE -p udp --dport 51820 -j ACCEPT
    iptables -A INPUT -i $UPSTREAM_INTERFACE -p udp --sport 51820 -j ACCEPT

    # Allow DHCP on upstream
    iptables -A OUTPUT -o $UPSTREAM_INTERFACE -p udp --dport 67:68 -j ACCEPT
    iptables -A INPUT -i $UPSTREAM_INTERFACE -p udp --sport 67:68 -j ACCEPT

    # Allow all through VPN
    iptables -A OUTPUT -o $VPN_INTERFACE -j ACCEPT
    iptables -A INPUT -i $VPN_INTERFACE -j ACCEPT

    # Forward AP traffic through VPN
    iptables -A FORWARD -i $AP_INTERFACE -o $VPN_INTERFACE -j ACCEPT
    iptables -A FORWARD -i $VPN_INTERFACE -o $AP_INTERFACE -j ACCEPT

    # NAT AP traffic through VPN
    iptables -t nat -A POSTROUTING -s $AP_SUBNET -o $VPN_INTERFACE -j MASQUERADE
fi

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}VPN is connected!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""

# Show VPN status
if [[ "$VPN_METHOD" == "nordvpn" ]]; then
    nordvpn status
else
    echo "WireGuard Status:"
    wg show
fi

echo ""
echo "Testing connection..."

# Get public IP through VPN
PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "Could not determine")
echo "Your public IP: $PUBLIC_IP"

echo ""
echo -e "${GREEN}All AP client traffic is now routed through VPN${NC}"
echo ""
echo "To check for DNS leaks: https://dnsleaktest.com"

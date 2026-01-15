#!/bin/bash
# Start the WiFi Access Point
# Usage: sudo ./start-ap.sh

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

echo -e "${GREEN}Starting WiFi Access Point on $AP_INTERFACE...${NC}"

# Unblock WiFi if blocked
rfkill unblock wifi 2>/dev/null || true

# Bring up the interface
ip link set $AP_INTERFACE up 2>/dev/null || true

# Disable power saving to reduce long-uptime disconnects
iw dev "$AP_INTERFACE" set power_save off 2>/dev/null || true

# Ensure static IP is set
if ! ip addr show $AP_INTERFACE | grep -q "192.168.4.1"; then
    ip addr add 192.168.4.1/24 dev $AP_INTERFACE 2>/dev/null || true
fi

# Stop services first (in case they're running)
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# Small delay to ensure interface is ready
sleep 1

# Start hostapd FIRST (this creates the AP interface properly)
echo "Starting hostapd..."
systemctl start hostapd
if systemctl is-active --quiet hostapd; then
    echo -e "${GREEN}hostapd started successfully${NC}"
else
    echo -e "${RED}Failed to start hostapd${NC}"
    systemctl status hostapd
    exit 1
fi

# Wait for interface to be fully initialized
sleep 2

# Ensure static IP is set after hostapd starts
ip addr add 192.168.4.1/24 dev $AP_INTERFACE 2>/dev/null || true

# Start dnsmasq (DHCP/DNS) - must start AFTER hostapd
echo "Starting dnsmasq..."
systemctl start dnsmasq
if systemctl is-active --quiet dnsmasq; then
    echo -e "${GREEN}dnsmasq started successfully${NC}"
else
    echo -e "${RED}Failed to start dnsmasq${NC}"
    systemctl status dnsmasq
    exit 1
fi

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Access Point is running!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo "SSID: $(grep '^ssid=' /etc/hostapd/hostapd.conf | cut -d= -f2)"
echo "IP: 192.168.4.1"
echo "DHCP Range: 192.168.4.50 - 192.168.4.150"
echo ""
echo "Connected clients can be viewed with:"
echo "  sudo arp -a | grep 192.168.4"
echo ""

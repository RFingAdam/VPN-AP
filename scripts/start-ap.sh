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

# Configuration — pick up AP_MODE / AP_INTERFACES from defaults when present.
[ -f /etc/default/vpn-ap ] && . /etc/default/vpn-ap
AP_INTERFACE="${AP_INTERFACE:-wlan1}"
AP_MODE="${AP_MODE:-single}"
AP_INTERFACES="${AP_INTERFACES:-$AP_INTERFACE}"

echo -e "${GREEN}Starting WiFi Access Point (mode=$AP_MODE, ifaces=$AP_INTERFACES)...${NC}"

# Unblock WiFi if blocked + apply no-power-save on every AP interface
rfkill unblock wifi 2>/dev/null || true
for _ap in $AP_INTERFACES; do
    ip link set "$_ap" up 2>/dev/null || true
    iw dev "$_ap" set power_save off 2>/dev/null || true
done

if [ "$AP_MODE" = "dual" ]; then
    # Dual mode: vpn-ap-mode (called by our ExecStartPre) already rendered
    # runtime configs and started vpn-ap-hostapd@<iface> template instances.
    # Just verify and poke if any are missing.
    sleep 1
    for _ap in $AP_INTERFACES; do
        if ! systemctl is-active --quiet "vpn-ap-hostapd@$_ap"; then
            echo "  starting vpn-ap-hostapd@$_ap..."
            systemctl start "vpn-ap-hostapd@$_ap" || true
        fi
    done
    # dnsmasq was already restarted by vpn-ap-mode; just make sure it's active.
    if ! systemctl is-active --quiet dnsmasq; then
        systemctl start dnsmasq
    fi

    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}Dual-AP is running!${NC}"
    echo -e "${GREEN}================================${NC}"
    for _ap in $AP_INTERFACES; do
        if systemctl is-active --quiet "vpn-ap-hostapd@$_ap"; then
            printf "  %-8s active  (%s)\n" "$_ap" "$(ip -4 -br addr show "$_ap" 2>/dev/null | awk '{print $3}')"
        else
            printf "  %-8s INACTIVE\n" "$_ap"
        fi
    done
    echo ""
    exit 0
fi

# Single mode (legacy path)
# Ensure static IP is set
if ! ip addr show "$AP_INTERFACE" | grep -q "192.168.4.1"; then
    ip addr add 192.168.4.1/24 dev "$AP_INTERFACE" 2>/dev/null || true
fi

# Stop services first (in case they're running)
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
sleep 1

# Prefer the vpn-ap-hostapd@<iface> template unit if enabled (v1.6+);
# fall back to the stock hostapd.service for pre-v1.6 installs.
echo "Starting hostapd..."
if systemctl list-unit-files "vpn-ap-hostapd@${AP_INTERFACE}.service" 2>/dev/null | grep -q enabled; then
    systemctl start "vpn-ap-hostapd@${AP_INTERFACE}"
    _hostapd_unit="vpn-ap-hostapd@${AP_INTERFACE}"
else
    systemctl start hostapd
    _hostapd_unit="hostapd"
fi
if systemctl is-active --quiet "$_hostapd_unit"; then
    echo -e "${GREEN}$_hostapd_unit started successfully${NC}"
else
    echo -e "${RED}Failed to start $_hostapd_unit${NC}"
    systemctl status "$_hostapd_unit"
    exit 1
fi

sleep 2
ip addr add 192.168.4.1/24 dev "$AP_INTERFACE" 2>/dev/null || true

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

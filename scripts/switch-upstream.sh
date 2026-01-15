#!/bin/bash
# Switch between Ethernet and WiFi upstream connections
# Usage: sudo ./switch-upstream.sh [ethernet|wifi]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
VPN_START_CMD="${VPN_START_CMD:-/usr/local/bin/vpn-start}"

if [ ! -x "$VPN_START_CMD" ]; then
    VPN_START_CMD="$(dirname "$0")/start-vpn.sh"
fi

show_status() {
    echo -e "${GREEN}Current Network Status:${NC}"
    echo ""

    # Ethernet status
    if ip link show eth0 2>/dev/null | grep -q "state UP"; then
        ETH_IP=$(ip addr show eth0 | grep "inet " | awk '{print $2}' | head -1)
        echo -e "  Ethernet (eth0): ${GREEN}UP${NC} - $ETH_IP"
    else
        echo -e "  Ethernet (eth0): ${YELLOW}DOWN${NC}"
    fi

    # Built-in WiFi status
    if ip link show wlan0 2>/dev/null | grep -q "state UP"; then
        WLAN_IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | head -1)
        SSID=$(iwconfig wlan0 2>/dev/null | grep ESSID | sed 's/.*ESSID:"\([^"]*\)".*/\1/')
        echo -e "  WiFi (wlan0): ${GREEN}UP${NC} - $WLAN_IP (SSID: $SSID)"
    else
        echo -e "  WiFi (wlan0): ${YELLOW}DOWN${NC}"
    fi

    # VPN status (check both NordVPN and WireGuard)
    if command -v nordvpn &> /dev/null && nordvpn status 2>/dev/null | grep -q "Connected"; then
        echo -e "  VPN (NordVPN): ${GREEN}CONNECTED${NC}"
    elif ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "UP"; then
        echo -e "  VPN ($VPN_INTERFACE): ${GREEN}CONNECTED${NC}"
    else
        echo -e "  VPN: ${YELLOW}DISCONNECTED${NC}"
    fi
    fi

    echo ""
}

use_ethernet() {
    echo -e "${GREEN}Switching to Ethernet upstream...${NC}"

    # Check if ethernet cable is connected
    if ! ip link show eth0 2>/dev/null | grep -q "state UP"; then
        echo -e "${YELLOW}Bringing up eth0...${NC}"
        ip link set eth0 up

        # Wait for connection
        sleep 3

        # Request DHCP
        dhclient eth0 2>/dev/null || dhcpcd eth0 2>/dev/null || true
        sleep 2
    fi

    if ip link show eth0 | grep -q "state UP"; then
        echo -e "${GREEN}Ethernet is UP${NC}"

        # Optionally disable wlan0 to save power
        read -p "Disable WiFi (wlan0) to save power? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ip link set wlan0 down 2>/dev/null || true
            echo "WiFi disabled"
        fi

        # Restart VPN to use new route
        echo "Restarting VPN..."
        VPN_FORCE_RECONNECT=1 "$VPN_START_CMD"

        show_status
    else
        echo -e "${RED}Ethernet is not connected. Is the cable plugged in?${NC}"
        exit 1
    fi
}

use_wifi() {
    echo -e "${GREEN}Switching to WiFi upstream...${NC}"

    # Check if wlan0 is up and connected
    if ! ip link show wlan0 2>/dev/null | grep -q "state UP"; then
        echo -e "${YELLOW}Bringing up wlan0...${NC}"
        ip link set wlan0 up
        rfkill unblock wifi 2>/dev/null || true
        sleep 2
    fi

    # Check if connected to a network
    if ! iwconfig wlan0 2>/dev/null | grep -q 'ESSID:"[^"]*"'; then
        echo ""
        echo "Available WiFi networks:"
        nmcli dev wifi list 2>/dev/null || iwlist wlan0 scan 2>/dev/null | grep ESSID || true
        echo ""
        read -p "Enter WiFi SSID: " SSID
        read -sp "Enter WiFi password: " PASSWORD
        echo ""

        nmcli dev wifi connect "$SSID" password "$PASSWORD" 2>/dev/null || \
        wpa_supplicant -B -i wlan0 -c <(wpa_passphrase "$SSID" "$PASSWORD") 2>/dev/null || true

        sleep 5
        dhclient wlan0 2>/dev/null || dhcpcd wlan0 2>/dev/null || true
        sleep 2
    fi

    if iwconfig wlan0 2>/dev/null | grep -q 'ESSID:"[^"]*"'; then
        echo -e "${GREEN}WiFi is connected${NC}"

        # Restart VPN to use new route
        echo "Restarting VPN..."
        VPN_FORCE_RECONNECT=1 "$VPN_START_CMD"

        show_status
    else
        echo -e "${RED}Failed to connect to WiFi${NC}"
        exit 1
    fi
}

# Main
case "${1:-status}" in
    ethernet|eth)
        use_ethernet
        ;;
    wifi|wlan)
        use_wifi
        ;;
    status|*)
        show_status
        echo "Usage: $0 [ethernet|wifi|status]"
        echo ""
        echo "  ethernet - Switch to Ethernet (eth0) upstream"
        echo "  wifi     - Switch to WiFi (wlan0) upstream"
        echo "  status   - Show current network status"
        ;;
esac

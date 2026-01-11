#!/bin/bash
# Emergency Recovery Script for VPN-AP
# Run this if you're locked out or having issues
# Can be triggered via SSH or physical console

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    VPN-AP Emergency Recovery Script    ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Function to reset everything to a safe state
reset_firewall() {
    echo -e "${YELLOW}Resetting firewall to allow all traffic...${NC}"
    iptables -F
    iptables -t nat -F
    iptables -X 2>/dev/null || true
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo -e "${GREEN}Firewall reset complete - all traffic allowed${NC}"
}

restart_ap_services() {
    echo -e "${YELLOW}Restarting AP services...${NC}"

    # Stop everything first
    systemctl stop captive-portal 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl stop hostapd 2>/dev/null || true

    # Bring up AP interface
    AP_IF="${AP_IF:-wlan1}"
    rfkill unblock wifi 2>/dev/null || true
    ip link set $AP_IF up 2>/dev/null || true
    ip addr flush dev $AP_IF 2>/dev/null || true
    ip addr add 192.168.4.1/24 dev $AP_IF 2>/dev/null || true

    sleep 2

    # Remove any DNS redirect
    rm -f /etc/dnsmasq.d/captive-portal.conf

    # Start services
    systemctl start hostapd
    sleep 2
    systemctl start dnsmasq
    sleep 1
    systemctl start captive-portal

    echo -e "${GREEN}AP services restarted${NC}"
}

disconnect_vpn() {
    echo -e "${YELLOW}Disconnecting VPN...${NC}"
    nordvpn disconnect 2>/dev/null || true
    wg-quick down wg0 2>/dev/null || true
    echo -e "${GREEN}VPN disconnected${NC}"
}

show_status() {
    echo ""
    echo -e "${GREEN}=== Current Status ===${NC}"
    echo ""

    # Network interfaces
    echo "Network Interfaces:"
    ip -br addr show 2>/dev/null || ip addr show

    echo ""
    echo "Services:"
    for svc in ssh hostapd dnsmasq captive-portal; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "  $svc: ${GREEN}running${NC}"
        else
            echo -e "  $svc: ${RED}stopped${NC}"
        fi
    done

    echo ""
    echo "VPN Status:"
    nordvpn status 2>/dev/null || echo "  NordVPN not available"

    echo ""
    echo "Access Points:"
    echo "  SSH: port 22 on all interfaces"
    echo "  Portal: http://192.168.4.1/"
    echo "  AP SSID: TravelRouter"
}

case "${1:-help}" in
    reset)
        reset_firewall
        ;;
    restart)
        restart_ap_services
        ;;
    full)
        echo -e "${YELLOW}Performing full recovery...${NC}"
        disconnect_vpn
        reset_firewall
        restart_ap_services
        show_status
        echo ""
        echo -e "${GREEN}Full recovery complete!${NC}"
        ;;
    status)
        show_status
        ;;
    vpn-off)
        disconnect_vpn
        reset_firewall
        ;;
    *)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  reset     - Reset firewall to allow all traffic"
        echo "  restart   - Restart AP services (hostapd, dnsmasq, portal)"
        echo "  full      - Full recovery: disconnect VPN, reset firewall, restart services"
        echo "  status    - Show current system status"
        echo "  vpn-off   - Disconnect VPN and reset firewall"
        echo ""
        echo "Emergency access:"
        echo "  - SSH is always available on port 22"
        echo "  - Connect to 'TravelRouter' WiFi, go to http://192.168.4.1/"
        echo "  - Emergency page: http://192.168.4.1/emergency"
        ;;
esac

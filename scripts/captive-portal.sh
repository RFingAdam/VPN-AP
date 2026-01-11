#!/bin/bash
# Temporarily bypass VPN to access hotel captive portal
# Usage: sudo ./captive-portal.sh
#
# This script:
# 1. Temporarily allows direct internet access (bypassing VPN)
# 2. Opens a simple way to access the captive portal
# 3. Waits for you to complete the login
# 4. Re-enables VPN protection

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

AP_INTERFACE="${AP_INTERFACE:-wlan1}"
AP_SUBNET="192.168.4.0/24"

# Detect upstream
if ip link show eth0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM="eth0"
else
    UPSTREAM="wlan0"
fi

# Detect VPN method
if command -v nordvpn &> /dev/null && nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
    VPN_METHOD="nordvpn"
elif ip link show wg0 2>/dev/null | grep -q "UP"; then
    VPN_METHOD="wireguard"
else
    VPN_METHOD="none"
fi

enable_captive_portal_access() {
    echo -e "${YELLOW}================================${NC}"
    echo -e "${YELLOW}CAPTIVE PORTAL MODE${NC}"
    echo -e "${YELLOW}================================${NC}"
    echo ""
    echo -e "${RED}WARNING: VPN protection is temporarily disabled!${NC}"
    echo "Your traffic will go directly to the hotel network."
    echo ""

    # Stop VPN based on method
    echo "Stopping VPN..."
    if [[ "$VPN_METHOD" == "nordvpn" ]]; then
        nordvpn disconnect 2>/dev/null || true
    elif [[ "$VPN_METHOD" == "wireguard" ]]; then
        wg-quick down wg0 2>/dev/null || true
    fi

    sleep 2

    # Clear restrictive rules
    iptables -F
    iptables -t nat -F

    # Set permissive policies
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # Enable NAT through upstream (for AP clients to access captive portal)
    iptables -t nat -A POSTROUTING -s $AP_SUBNET -o $UPSTREAM -j MASQUERADE

    # Enable forwarding
    iptables -A FORWARD -i $AP_INTERFACE -o $UPSTREAM -j ACCEPT
    iptables -A FORWARD -i $UPSTREAM -o $AP_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    echo ""
    echo -e "${GREEN}Captive portal access enabled!${NC}"
    echo ""
    echo "To access the captive portal:"
    echo ""
    echo "  Option 1: From a connected device (phone/laptop)"
    echo "    - Open any HTTP website (not HTTPS)"
    echo "    - Try: http://neverssl.com or http://captive.apple.com"
    echo "    - You should be redirected to the hotel login page"
    echo ""
    echo "  Option 2: From the Pi itself"
    echo "    - curl -L http://captive.apple.com"
    echo "    - Or use a text browser: lynx http://neverssl.com"
    echo ""

    # Try to detect captive portal
    echo "Checking for captive portal..."
    PORTAL_CHECK=$(curl -s -L -o /dev/null -w '%{url_effective}' --max-time 10 http://captive.apple.com 2>/dev/null || echo "")

    if [ -n "$PORTAL_CHECK" ] && [ "$PORTAL_CHECK" != "http://captive.apple.com" ]; then
        echo -e "${GREEN}Captive portal detected!${NC}"
        echo "Portal URL: $PORTAL_CHECK"
    else
        echo "No captive portal redirect detected (might already be authenticated)"
    fi

    echo ""
}

restore_vpn() {
    echo ""
    echo "Restoring VPN protection..."

    # Restart the VPN with full protection
    if [[ "$VPN_METHOD" == "nordvpn" ]] || command -v nordvpn &> /dev/null; then
        echo "Reconnecting NordVPN..."
        nordvpn connect
        sleep 3
        # Re-add forwarding rules for AP
        VPN_INTERFACE=$(ip link show | grep -oE "nordlynx[0-9]*" | head -1)
        if [ -n "$VPN_INTERFACE" ]; then
            iptables -t nat -A POSTROUTING -s $AP_SUBNET -o $VPN_INTERFACE -j MASQUERADE
            iptables -I FORWARD 1 -i $AP_INTERFACE -o $VPN_INTERFACE -j ACCEPT
            iptables -I FORWARD 2 -i $VPN_INTERFACE -o $AP_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        fi
        echo -e "${GREEN}NordVPN protection restored!${NC}"
    elif [ -f /etc/wireguard/wg0.conf ]; then
        # Run the start-vpn script which sets up kill switch
        /usr/local/bin/vpn-start 2>/dev/null || bash "$(dirname "$0")/start-vpn.sh"
        echo -e "${GREEN}VPN protection restored!${NC}"
    else
        echo -e "${YELLOW}No VPN configured. Traffic is unprotected.${NC}"
    fi
}

cleanup() {
    echo ""
    echo "Caught interrupt, restoring VPN..."
    restore_vpn
    exit 0
}

# Main
trap cleanup INT TERM

enable_captive_portal_access

echo ""
echo -e "${YELLOW}Press ENTER when you've completed the captive portal login...${NC}"
echo "(or Ctrl+C to cancel and restore VPN)"
read

restore_vpn

echo ""
echo -e "${GREEN}Done! VPN protection is active again.${NC}"
echo "Your AP clients can now access the internet through VPN."

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
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
AP_SUBNET="192.168.4.0/24"
VPN_STOP_CMD="${VPN_STOP_CMD:-/usr/local/bin/vpn-stop}"
VPN_START_CMD="${VPN_START_CMD:-/usr/local/bin/vpn-start}"

if [ ! -x "$VPN_STOP_CMD" ]; then
    VPN_STOP_CMD="$(dirname "$0")/stop-vpn.sh"
fi

if [ ! -x "$VPN_START_CMD" ]; then
    VPN_START_CMD="$(dirname "$0")/start-vpn.sh"
fi

# Detect upstream
if ip link show eth0 2>/dev/null | grep -q "state UP"; then
    UPSTREAM="eth0"
else
    UPSTREAM="wlan0"
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
    "$VPN_STOP_CMD"
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
    if "$VPN_START_CMD" 2>/dev/null; then
        echo -e "${GREEN}VPN protection restored!${NC}"
    else
        echo -e "${YELLOW}VPN restore failed. Check VPN configuration.${NC}"
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

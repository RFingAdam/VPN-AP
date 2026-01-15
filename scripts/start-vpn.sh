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
VPN_MODE="${VPN_MODE:-auto}"
VPN_INTERFACE="${VPN_INTERFACE:-}"
VPN_INTERFACE_DEFAULTED=0
if [ -z "$VPN_INTERFACE" ]; then
    VPN_INTERFACE="wg0"
    VPN_INTERFACE_DEFAULTED=1
fi
VPN_ENDPOINT_PORT="${VPN_ENDPOINT_PORT:-}"
VPN_FORCE_RECONNECT="${VPN_FORCE_RECONNECT:-0}"
AP_INTERFACE="${AP_INTERFACE:-wlan1}"
AP_SUBNET="192.168.4.0/24"
UPSTREAM_INTERFACES="${UPSTREAM_INTERFACES:-eth0 wlan0}"

# Parse arguments
if [[ "$1" == "--wireguard" ]]; then
    VPN_MODE="wireguard"
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

wait_for_interface() {
    local iface="$1"
    local retries="${2:-15}"
    local i
    for i in $(seq 1 "$retries"); do
        if ip link show "$iface" 2>/dev/null | grep -q "UP"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

resolve_vpn_port() {
    local port=""
    if [ -n "$VPN_ENDPOINT_PORT" ]; then
        echo "$VPN_ENDPOINT_PORT"
        return 0
    fi

    if command_exists wg; then
        port=$(wg show "$VPN_INTERFACE" endpoints 2>/dev/null | awk '{print $2}' | tail -1)
        port="${port##*:}"
    fi

    if [ -z "$port" ] && [ -f "/etc/wireguard/${VPN_INTERFACE}.conf" ]; then
        local endpoint
        endpoint=$(grep -E "^Endpoint" "/etc/wireguard/${VPN_INTERFACE}.conf" | tail -1 | awk -F'= ' '{print $2}')
        if [ -n "$endpoint" ]; then
            port="${endpoint##*:}"
        fi
    fi

    if [ -z "$port" ]; then
        port="51820"
    fi

    echo "$port"
}

get_default_route_interface() {
    ip route show default 0.0.0.0/0 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }'
}

get_best_upstream() {
    local iface
    iface="$(get_default_route_interface)"
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi

    for iface in $UPSTREAM_INTERFACES; do
        if ip link show "$iface" >/dev/null 2>&1; then
            if ip link show "$iface" | grep -q "state UP"; then
                echo "$iface"
                return 0
            fi
        fi
    done

    return 1
}

add_upstream_rules() {
    local iface="$1"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        return 0
    fi

    # Allow VPN tunnel to upstream (port auto-detected or overridden)
    iptables -A OUTPUT -o "$iface" -p udp --dport "$VPN_PORT" -j ACCEPT
    iptables -A INPUT -i "$iface" -p udp --sport "$VPN_PORT" -j ACCEPT

    # Allow DHCP on upstream
    iptables -A OUTPUT -o "$iface" -p udp --dport 67:68 -j ACCEPT
    iptables -A INPUT -i "$iface" -p udp --sport 67:68 -j ACCEPT
}

echo -e "${GREEN}Starting VPN and configuring routing...${NC}"

# Determine VPN method
case "$VPN_MODE" in
    wireguard)
        VPN_METHOD="wireguard"
        ;;
    nordvpn)
        VPN_METHOD="nordvpn"
        ;;
    auto)
        if command_exists nordvpn; then
            VPN_METHOD="nordvpn"
        elif [ -f "/etc/wireguard/${VPN_INTERFACE}.conf" ] || [ -f /etc/wireguard/wg0.conf ]; then
            VPN_METHOD="wireguard"
        else
            echo -e "${RED}Error: No VPN method available!${NC}"
            echo "Install NordVPN CLI or configure WireGuard."
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Error: Unknown VPN_MODE '$VPN_MODE'.${NC}"
        exit 1
        ;;
esac

echo "Using VPN method: $VPN_METHOD"

if [ "$VPN_METHOD" = "nordvpn" ] && [ "$VPN_INTERFACE_DEFAULTED" -eq 1 ]; then
    VPN_INTERFACE="nordlynx"
fi

# Detect upstream interface (for status/logging)
UPSTREAM_INTERFACE="$(get_best_upstream || true)"
if [ -n "$UPSTREAM_INTERFACE" ]; then
    if [ "$UPSTREAM_INTERFACE" = "eth0" ]; then
        echo "Using Ethernet (eth0) as upstream"
    elif [ "$UPSTREAM_INTERFACE" = "wlan0" ]; then
        echo "Using WiFi (wlan0) as upstream"
    else
        echo "Using $UPSTREAM_INTERFACE as upstream"
    fi
else
    echo -e "${YELLOW}Warning: No upstream interface detected as UP${NC}"
    echo "Allowing DHCP/VPN on: $UPSTREAM_INTERFACES"
    UPSTREAM_INTERFACE="$(echo "$UPSTREAM_INTERFACES" | awk '{print $1}')"
fi
if [ -n "$UPSTREAM_INTERFACE" ] && ! echo " $UPSTREAM_INTERFACES " | grep -q " $UPSTREAM_INTERFACE "; then
    UPSTREAM_INTERFACES="$UPSTREAM_INTERFACES $UPSTREAM_INTERFACE"
fi

if [[ "$VPN_METHOD" == "nordvpn" ]]; then
    if ! command_exists nordvpn; then
        echo -e "${RED}Error: nordvpn CLI not found.${NC}"
        exit 1
    fi

    # ============================================
    # NordVPN CLI Method
    # ============================================

    # Ensure NordVPN settings are correct for AP routing
    echo "Configuring NordVPN settings..."
    nordvpn set lan-discovery enabled 2>/dev/null || true
    nordvpn allowlist add port 22 2>/dev/null || true

    if [ "$VPN_FORCE_RECONNECT" = "1" ]; then
        nordvpn disconnect 2>/dev/null || true
    fi

    # Connect to NordVPN if needed
    echo "Connecting to NordVPN..."
    if ! nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
        nordvpn connect
    else
        nordvpn status >/dev/null || true
    fi

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
    DETECTED_INTERFACE=$(ip link show | grep -oE "nordlynx[0-9]*|nordtun[0-9]*" | head -1)
    if [ -n "$DETECTED_INTERFACE" ]; then
        VPN_INTERFACE="$DETECTED_INTERFACE"
    elif [ -z "$VPN_INTERFACE" ]; then
        echo -e "${YELLOW}Could not detect NordVPN interface, using nordlynx${NC}"
        VPN_INTERFACE="nordlynx"
    fi
else
    # ============================================
    # WireGuard Method
    # ============================================
    if [ ! -f "/etc/wireguard/${VPN_INTERFACE}.conf" ]; then
        echo -e "${RED}Error: /etc/wireguard/${VPN_INTERFACE}.conf not found!${NC}"
        echo "Please configure WireGuard or install NordVPN CLI"
        exit 1
    fi

    # Check for placeholder values
    if grep -q "YOUR_NORDVPN_PRIVATE_KEY_HERE" "/etc/wireguard/${VPN_INTERFACE}.conf"; then
        echo -e "${RED}Error: WireGuard config still has placeholder values!${NC}"
        exit 1
    fi

    # Stop VPN if running
    wg-quick down "$VPN_INTERFACE" 2>/dev/null || true

    # Start WireGuard VPN
    echo "Starting WireGuard..."
    wg-quick up "$VPN_INTERFACE"

    if ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "UP"; then
        echo -e "${GREEN}WireGuard started successfully${NC}"
    else
        echo -e "${RED}Failed to start WireGuard${NC}"
        exit 1
    fi
fi

if wait_for_interface "$VPN_INTERFACE" 15; then
    echo -e "${GREEN}VPN interface is up ($VPN_INTERFACE)${NC}"
else
    echo -e "${RED}Failed to bring up VPN interface: $VPN_INTERFACE${NC}"
    if [ "$VPN_METHOD" = "nordvpn" ]; then
        echo "Ensure NordVPN is set to NordLynx or set VPN_INTERFACE accordingly."
    fi
    exit 1
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
    for iface in $UPSTREAM_INTERFACES; do
        if ip link show "$iface" >/dev/null 2>&1; then
            iptables -A INPUT -i "$iface" -p tcp --dport 22 -j ACCEPT
        fi
    done

    # Allow DHCP/DNS on AP interface
    iptables -A INPUT -i $AP_INTERFACE -p udp --dport 67 -j ACCEPT
    iptables -A INPUT -i $AP_INTERFACE -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -i $AP_INTERFACE -p icmp --icmp-type echo-request -j ACCEPT

    # Allow VPN tunnel + DHCP on upstream interfaces
    VPN_PORT=$(resolve_vpn_port)
    for iface in $UPSTREAM_INTERFACES; do
        add_upstream_rules "$iface"
    done

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
    if command_exists wg; then
        wg show "$VPN_INTERFACE" 2>/dev/null || true
    else
        echo "wg tool not found"
    fi
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
if [ "$VPN_METHOD" = "nordvpn" ]; then
    echo "To verify kill switch: sudo nordvpn disconnect"
else
    echo "To verify kill switch: sudo systemctl stop wg-quick@$VPN_INTERFACE"
fi
echo "  (Traffic should stop completely)"

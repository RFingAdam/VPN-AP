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

# Source defaults for HaLow configuration
[ -f /etc/default/vpn-ap ] && . /etc/default/vpn-ap

# HaLow (802.11ah) configuration
HALOW_ENABLED="${HALOW_ENABLED:-0}"
HALOW_INTERFACE="${HALOW_INTERFACE:-wlan2}"
HALOW_CONNECTION_METHOD="${HALOW_CONNECTION_METHOD:-wpa_supplicant}"
HALOW_SSID="${HALOW_SSID:-}"
HALOW_PASSWORD="${HALOW_PASSWORD:-}"
HALOW_SECURITY="${HALOW_SECURITY:-sae}"
HALOW_COUNTRY="${HALOW_COUNTRY:-US}"
NRC_PKG_PATH="${NRC_PKG_PATH:-/home/pi/nrc_pkg}"

# Check if HaLow hardware is available
halow_available() {
    [ "$HALOW_ENABLED" != "1" ] && return 1
    ip link show "$HALOW_INTERFACE" &>/dev/null && return 0
    lsmod | grep -q "nrc" && return 0
    modinfo nrc &>/dev/null 2>&1 && return 0
    return 1
}

# Check if HaLow is connected with IP
halow_connected() {
    ip link show "$HALOW_INTERFACE" 2>/dev/null | grep -q "state UP" || return 1
    ip addr show "$HALOW_INTERFACE" 2>/dev/null | grep -q "inet " || return 1
    return 0
}

# Get HaLow connection status
halow_status() {
    halow_available || { echo "unavailable"; return; }
    ip link show "$HALOW_INTERFACE" &>/dev/null || { echo "not-loaded"; return; }
    ip link show "$HALOW_INTERFACE" | grep -q "state UP" || { echo "down"; return; }
    ip addr show "$HALOW_INTERFACE" | grep -q "inet " || { echo "no-ip"; return; }
    local ssid=""
    if command -v iwconfig &>/dev/null; then
        ssid=$(iwconfig "$HALOW_INTERFACE" 2>/dev/null | grep ESSID | sed 's/.*ESSID:"\([^"]*\)".*/\1/')
    fi
    [ -n "$ssid" ] && echo "connected:$ssid" || echo "connected"
}

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

    # HaLow status (if enabled)
    if [ "$HALOW_ENABLED" = "1" ]; then
        local hstatus=$(halow_status)
        case "$hstatus" in
            unavailable)
                echo -e "  HaLow ($HALOW_INTERFACE): ${RED}UNAVAILABLE${NC}"
                ;;
            not-loaded)
                echo -e "  HaLow ($HALOW_INTERFACE): ${YELLOW}DRIVER NOT LOADED${NC}"
                ;;
            down)
                echo -e "  HaLow ($HALOW_INTERFACE): ${YELLOW}DOWN${NC}"
                ;;
            no-ip)
                echo -e "  HaLow ($HALOW_INTERFACE): ${YELLOW}NO IP${NC}"
                ;;
            connected:*)
                local halow_ssid="${hstatus#connected:}"
                local halow_ip=$(ip addr show "$HALOW_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
                echo -e "  HaLow ($HALOW_INTERFACE): ${GREEN}UP${NC} - $halow_ip (SSID: $halow_ssid)"
                ;;
            connected)
                local halow_ip=$(ip addr show "$HALOW_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
                echo -e "  HaLow ($HALOW_INTERFACE): ${GREEN}UP${NC} - $halow_ip"
                ;;
        esac
    fi

    # VPN status (check both NordVPN and WireGuard)
    if command -v nordvpn &> /dev/null && nordvpn status 2>/dev/null | grep -q "Connected"; then
        echo -e "  VPN (NordVPN): ${GREEN}CONNECTED${NC}"
    elif ip link show "$VPN_INTERFACE" 2>/dev/null | grep -q "UP"; then
        echo -e "  VPN ($VPN_INTERFACE): ${GREEN}CONNECTED${NC}"
    else
        echo -e "  VPN: ${YELLOW}DISCONNECTED${NC}"
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

# Generate wpa_supplicant config for HaLow
generate_halow_wpa_conf() {
    local conf_file="$1"

    cat > "$conf_file" << EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$HALOW_COUNTRY

network={
    ssid="$HALOW_SSID"
    scan_ssid=1
EOF

    case "$HALOW_SECURITY" in
        open)
            cat >> "$conf_file" << EOF
    key_mgmt=NONE
}
EOF
            ;;
        wpa2)
            cat >> "$conf_file" << EOF
    key_mgmt=WPA-PSK
    psk="$HALOW_PASSWORD"
}
EOF
            ;;
        sae|wpa3)
            cat >> "$conf_file" << EOF
    key_mgmt=SAE
    psk="$HALOW_PASSWORD"
    ieee80211w=2
}
EOF
            ;;
        *)
            # Default to SAE
            cat >> "$conf_file" << EOF
    key_mgmt=SAE
    psk="$HALOW_PASSWORD"
    ieee80211w=2
}
EOF
            ;;
    esac

    chmod 600 "$conf_file"
}

# Connect to HaLow using wpa_supplicant
connect_halow_wpa_supplicant() {
    echo "Connecting via wpa_supplicant..."

    # Ensure the Newracom driver is loaded
    if ! lsmod | grep -q "nrc"; then
        echo "Loading Newracom driver..."
        modprobe mac80211 2>/dev/null || true

        # Try to load nrc module with country code
        if ! modprobe nrc fw_country="$HALOW_COUNTRY" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Could not load nrc module with modprobe${NC}"
        fi
        sleep 2
    fi

    # Bring up interface
    ip link set "$HALOW_INTERFACE" up 2>/dev/null || true
    sleep 1

    # Create wpa_supplicant configuration
    local wpa_conf="/tmp/halow_wpa_supplicant.conf"
    generate_halow_wpa_conf "$wpa_conf"

    # Kill any existing wpa_supplicant on this interface
    pkill -f "wpa_supplicant.*$HALOW_INTERFACE" 2>/dev/null || true
    sleep 1

    # Start wpa_supplicant
    wpa_supplicant -B -i "$HALOW_INTERFACE" -D nl80211 -c "$wpa_conf"
    sleep 3

    # Request DHCP
    dhclient "$HALOW_INTERFACE" 2>/dev/null || dhcpcd "$HALOW_INTERFACE" 2>/dev/null || true
}

# Connect using Newracom's start.py script
connect_halow_nrc_start_py() {
    echo "Connecting via Newracom start.py..."

    if [ ! -d "$NRC_PKG_PATH" ]; then
        echo -e "${RED}Newracom package not found at $NRC_PKG_PATH${NC}"
        exit 1
    fi

    # Map security type to start.py parameter
    local sec_param=3
    case "$HALOW_SECURITY" in
        open) sec_param=0 ;;
        wpa2) sec_param=1 ;;
        owe)  sec_param=2 ;;
        sae)  sec_param=3 ;;
        *)    sec_param=3 ;;  # Default to SAE
    esac

    # Run start.py for STA mode
    cd "$NRC_PKG_PATH/script"
    python3 ./start.py 0 "$sec_param" "$HALOW_COUNTRY"

    sleep 3

    # Request DHCP if start.py doesn't handle it
    if ! ip addr show "$HALOW_INTERFACE" 2>/dev/null | grep -q "inet "; then
        dhclient "$HALOW_INTERFACE" 2>/dev/null || dhcpcd "$HALOW_INTERFACE" 2>/dev/null || true
    fi
}

use_halow() {
    echo -e "${GREEN}Switching to HaLow (802.11ah) upstream...${NC}"

    # Pre-flight checks
    if ! halow_available; then
        echo -e "${RED}HaLow is not available.${NC}"
        echo "Ensure HALOW_ENABLED=1 in /etc/default/vpn-ap"
        echo "and that HaLow hardware/driver is installed."
        exit 1
    fi

    if [ -z "$HALOW_SSID" ]; then
        echo -e "${RED}HaLow SSID not configured.${NC}"
        echo "Set HALOW_SSID in /etc/default/vpn-ap"
        exit 1
    fi

    # Connect using configured method
    case "$HALOW_CONNECTION_METHOD" in
        wpa_supplicant)
            connect_halow_wpa_supplicant
            ;;
        nrc_start_py)
            connect_halow_nrc_start_py
            ;;
        *)
            echo -e "${RED}Unknown HaLow connection method: $HALOW_CONNECTION_METHOD${NC}"
            exit 1
            ;;
    esac

    # Wait for connection
    local retries=10
    local connected=0
    echo "Waiting for HaLow connection..."
    for i in $(seq 1 $retries); do
        sleep 2
        if halow_connected; then
            connected=1
            break
        fi
        echo "  Attempt $i/$retries..."
    done

    if [ "$connected" -eq 1 ]; then
        echo -e "${GREEN}HaLow is connected${NC}"
        local halow_ip=$(ip addr show "$HALOW_INTERFACE" | grep "inet " | awk '{print $2}' | head -1)
        echo "  Interface: $HALOW_INTERFACE"
        echo "  IP: $halow_ip"

        # Optionally disable other interfaces
        read -p "Disable WiFi (wlan0) and Ethernet to save power? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ip link set wlan0 down 2>/dev/null || true
            ip link set eth0 down 2>/dev/null || true
            echo "Other interfaces disabled"
        fi

        # Restart VPN to use new route
        echo "Restarting VPN..."
        VPN_FORCE_RECONNECT=1 "$VPN_START_CMD"

        show_status
    else
        echo -e "${RED}Failed to connect to HaLow network${NC}"
        echo "Check HaLow configuration and ensure the network is in range."
        exit 1
    fi
}

disconnect_halow() {
    echo "Disconnecting HaLow..."

    # Kill wpa_supplicant on HaLow interface
    pkill -f "wpa_supplicant.*$HALOW_INTERFACE" 2>/dev/null || true

    # Bring down interface
    ip link set "$HALOW_INTERFACE" down 2>/dev/null || true

    echo "HaLow disconnected"
    show_status
}

# Main
case "${1:-status}" in
    ethernet|eth)
        use_ethernet
        ;;
    wifi|wlan)
        use_wifi
        ;;
    halow|802.11ah)
        use_halow
        ;;
    halow-disconnect)
        disconnect_halow
        ;;
    status|*)
        show_status
        echo "Usage: $0 [ethernet|wifi|halow|halow-disconnect|status]"
        echo ""
        echo "  ethernet         - Switch to Ethernet (eth0) upstream"
        echo "  wifi             - Switch to WiFi (wlan0) upstream"
        echo "  halow            - Switch to HaLow 802.11ah ($HALOW_INTERFACE) upstream"
        echo "  halow-disconnect - Disconnect from HaLow network"
        echo "  status           - Show current network status"
        if [ "$HALOW_ENABLED" != "1" ]; then
            echo ""
            echo -e "  ${YELLOW}Note: HaLow is disabled. Set HALOW_ENABLED=1 in /etc/default/vpn-ap${NC}"
        fi
        ;;
esac

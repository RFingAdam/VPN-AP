#!/bin/bash
# VPN-AP Setup Script
# Run this on a fresh Raspberry Pi OS Lite installation
# Usage: sudo ./setup.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_DIR/config"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}VPN-AP Setup Script${NC}"
echo -e "${GREEN}================================${NC}"
echo ""

# Step 1: Update system
echo -e "${YELLOW}[1/7] Updating system packages...${NC}"
apt update
apt upgrade -y

# Step 2: Install required packages
echo -e "${YELLOW}[2/7] Installing required packages...${NC}"
apt install -y \
    hostapd \
    dnsmasq \
    wireguard \
    wireguard-tools \
    iptables \
    iptables-persistent \
    iw \
    rfkill \
    net-tools

# Step 3: Stop services during configuration
echo -e "${YELLOW}[3/7] Stopping services for configuration...${NC}"
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl unmask hostapd

# Step 4: Detect WiFi interfaces
echo -e "${YELLOW}[4/7] Detecting WiFi interfaces...${NC}"
echo ""

# List all wireless interfaces
echo "Available wireless interfaces:"
iw dev | grep -E "Interface|type" | head -20

echo ""
echo "Checking for USB WiFi adapter..."

# Try to identify interfaces
BUILTIN_WLAN=""
USB_WLAN=""

for iface in /sys/class/net/wlan*; do
    if [ -e "$iface" ]; then
        ifname=$(basename "$iface")
        device_path=$(readlink -f "$iface/device")

        if echo "$device_path" | grep -q "usb"; then
            USB_WLAN="$ifname"
            echo -e "  ${GREEN}Found USB WiFi: $ifname${NC}"
        else
            BUILTIN_WLAN="$ifname"
            echo -e "  ${GREEN}Found built-in WiFi: $ifname${NC}"
        fi
    fi
done

if [ -z "$USB_WLAN" ]; then
    echo -e "${RED}Warning: No USB WiFi adapter detected!${NC}"
    echo "Please plug in a USB WiFi adapter and run this script again."
    echo ""
    read -p "Continue anyway with wlan1 as default? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    USB_WLAN="wlan1"
fi

echo ""
echo "Configuration will use:"
echo "  - AP Interface (USB): $USB_WLAN"
echo "  - Upstream Interface: ${BUILTIN_WLAN:-eth0/wlan0}"

# Step 5: Check AP mode support
echo ""
echo -e "${YELLOW}[5/7] Checking AP mode support for $USB_WLAN...${NC}"

if iw list 2>/dev/null | grep -A 10 "Supported interface modes" | grep -q "AP"; then
    echo -e "${GREEN}AP mode is supported!${NC}"
else
    echo -e "${RED}Warning: Could not confirm AP mode support.${NC}"
    echo "The adapter might still work, but AP mode wasn't detected."
    echo "Check with: iw list | grep -A 10 'Supported interface modes'"
fi

# Step 6: Configure network interfaces
echo ""
echo -e "${YELLOW}[6/7] Configuring network interfaces...${NC}"

# Backup original dhcpcd.conf
cp /etc/dhcpcd.conf /etc/dhcpcd.conf.backup 2>/dev/null || true

# Add static IP for AP interface
if ! grep -q "interface $USB_WLAN" /etc/dhcpcd.conf; then
    cat >> /etc/dhcpcd.conf << EOF

# VPN-AP: Static IP for access point interface
interface $USB_WLAN
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF
    echo "Added static IP configuration for $USB_WLAN"
fi

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-vpn-ap.conf
sysctl -w net.ipv4.ip_forward=1

# Step 7: Install configuration files
echo ""
echo -e "${YELLOW}[7/7] Installing configuration files...${NC}"

# Update hostapd.conf with detected interface
sed "s/interface=wlan1/interface=$USB_WLAN/" "$CONFIG_DIR/hostapd.conf" > /etc/hostapd/hostapd.conf

# Update dnsmasq.conf with detected interface
sed "s/interface=wlan1/interface=$USB_WLAN/" "$CONFIG_DIR/dnsmasq.conf" > /etc/dnsmasq.d/vpn-ap.conf

# Disable default dnsmasq config if it conflicts
if [ -f /etc/dnsmasq.conf ]; then
    mv /etc/dnsmasq.conf /etc/dnsmasq.conf.original
    touch /etc/dnsmasq.conf
fi

# Point hostapd to config file
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# Create defaults for vpn-ap watchdog (do not overwrite)
DEFAULTS_FILE="/etc/default/vpn-ap"
if [ ! -f "$DEFAULTS_FILE" ]; then
    cat > "$DEFAULTS_FILE" << EOF
# VPN-AP configuration defaults
# Customize these values for your deployment

# Path to VPN-AP project directory (change if installed elsewhere)
PROJECT_DIR=$PROJECT_DIR

# Network interfaces
AP_INTERFACE=$USB_WLAN
VPN_INTERFACE=$VPN_INTERFACE
VPN_MODE=auto
UPSTREAM_INTERFACES="eth0 wlan0"

# Watchdog timing settings
CHECK_INTERVAL=30
AP_RESTART_COOLDOWN=60
VPN_RESTART_COOLDOWN=120
VPN_HANDSHAKE_MAX_AGE=180
STARTUP_DELAY=3
EOF
fi

# Copy WireGuard template if config doesn't exist
if [ ! -f "/etc/wireguard/${VPN_INTERFACE}.conf" ]; then
    cp "$CONFIG_DIR/wg0.conf.template" "/etc/wireguard/${VPN_INTERFACE}.conf.template"
    echo -e "${YELLOW}WireGuard template copied to /etc/wireguard/${VPN_INTERFACE}.conf.template${NC}"
    echo "You need to create /etc/wireguard/${VPN_INTERFACE}.conf with your NordVPN credentials"
fi

# Copy scripts to /usr/local/bin
cp "$SCRIPT_DIR/start-ap.sh" /usr/local/bin/vpn-ap-start
cp "$SCRIPT_DIR/start-vpn.sh" /usr/local/bin/vpn-start
cp "$SCRIPT_DIR/stop-vpn.sh" /usr/local/bin/vpn-stop
cp "$SCRIPT_DIR/switch-upstream.sh" /usr/local/bin/vpn-ap-switch
cp "$SCRIPT_DIR/captive-portal.sh" /usr/local/bin/captive-portal
cp "$SCRIPT_DIR/emergency-recovery.sh" /usr/local/bin/vpn-ap-emergency
cp "$SCRIPT_DIR/watchdog.sh" /usr/local/bin/vpn-ap-watchdog
cp "$SCRIPT_DIR/iptables-captive-mode.sh" /usr/local/bin/
cp "$SCRIPT_DIR/iptables-internet-mode.sh" /usr/local/bin/
cp "$SCRIPT_DIR/iptables-vpn-mode.sh" /usr/local/bin/
chmod +x /usr/local/bin/vpn-ap-*
chmod +x /usr/local/bin/vpn-start
chmod +x /usr/local/bin/vpn-stop
chmod +x /usr/local/bin/captive-portal
chmod +x /usr/local/bin/iptables-*.sh

# Add restart policies for core services
mkdir -p /etc/systemd/system/hostapd.service.d
cat > /etc/systemd/system/hostapd.service.d/vpn-ap.conf << 'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5
EOF

mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/vpn-ap.conf << 'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5
EOF

# Install systemd service
# Create state directory for recovery
mkdir -p /var/lib/vpn-ap
chown root:root /var/lib/vpn-ap

# Install systemd services
cp "$PROJECT_DIR/systemd/vpn-ap.service" /etc/systemd/system/
cp "$PROJECT_DIR/systemd/captive-portal.service" /etc/systemd/system/
cp "$PROJECT_DIR/systemd/vpn-ap-watchdog.service" /etc/systemd/system/
cp "$PROJECT_DIR/systemd/vpn-ap-watchdog.timer" /etc/systemd/system/
systemctl daemon-reload

# Enable watchdog timer for auto-recovery
systemctl enable vpn-ap-watchdog.timer
systemctl start vpn-ap-watchdog.timer

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Configure your WiFi AP password:"
echo "   sudo nano /etc/hostapd/hostapd.conf"
echo "   Change 'wpa_passphrase=ChangeMe123!' to your password"
echo ""
echo "2. Set up WireGuard with NordVPN credentials:"
echo "   sudo cp /etc/wireguard/wg0.conf.template /etc/wireguard/wg0.conf"
echo "   sudo nano /etc/wireguard/wg0.conf"
echo "   Fill in your NordVPN private key and server details"
echo ""
echo "3. Connect to hotel network:"
echo "   - Via Ethernet: Just plug in the cable"
echo "   - Via WiFi: sudo nmcli dev wifi connect 'HotelWiFi' password 'password'"
echo ""
echo "4. Start the VPN router:"
echo "   sudo systemctl start vpn-ap"
echo ""
echo "5. (Optional) Enable auto-start on boot:"
echo "   sudo systemctl enable vpn-ap"
echo ""
echo "Useful commands:"
echo "  sudo systemctl status vpn-ap    # Check status"
echo "  sudo vpn-ap-start               # Manually start AP"
echo "  sudo vpn-start                  # Manually start VPN"
echo "  sudo captive-portal             # Bypass VPN for hotel login"
echo ""
echo "Emergency recovery:"
echo "  sudo vpn-ap-emergency full      # Full recovery if locked out"
echo "  http://192.168.4.1/emergency    # Web-based emergency recovery"
echo "  SSH always available on port 22"
echo ""
echo "Automatic monitoring:"
echo "  Watchdog runs every minute to auto-recover services"
echo "  State is persisted for recovery after reboots"
echo ""

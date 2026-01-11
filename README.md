# VPN-AP: Travel VPN Router

Turn your Raspberry Pi into a portable VPN router. Connect your devices to a secure WiFi access point that routes all traffic through NordVPN.

## Features

- **Web-based Setup**: Connect to the AP and configure WiFi through a captive portal
- **NordVPN Integration**: Uses NordVPN CLI with NordLynx (WireGuard) protocol
- **Hotel WiFi Support**: Easy captive portal bypass for hotel/airport networks
- **Auto-start on Boot**: Just power on and connect
- **SSH Access Preserved**: Manage the Pi even when VPN is active

## Hardware Requirements

- Raspberry Pi 4 (or Pi 3B+)
- USB WiFi adapter that supports AP mode (for the access point)
- Power supply
- MicroSD card (8GB+)

The built-in WiFi (`wlan0`) connects to upstream networks (hotel WiFi), while the USB adapter (`wlan1`) hosts the access point.

## Quick Start

### 1. Install NordVPN

```bash
# Download and install NordVPN
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

# Login to NordVPN
nordvpn login

# Configure for AP routing
nordvpn set lan-discovery enabled
nordvpn allowlist add port 22
```

### 2. Clone and Setup

```bash
cd ~
git clone https://github.com/RFingAdam/VPN-AP.git
cd VPN-AP
sudo ./scripts/setup.sh
```

### 3. Configure AP Password

Edit `/etc/hostapd/hostapd.conf` and change `wpa_passphrase`:

```bash
sudo nano /etc/hostapd/hostapd.conf
```

### 4. Enable Auto-start

```bash
sudo systemctl daemon-reload
sudo systemctl enable vpn-ap
sudo systemctl enable captive-portal
```

### 5. Reboot

```bash
sudo reboot
```

## Usage

### First-time Setup (Hotel/New Location)

1. Power on the Raspberry Pi
2. Connect to **TravelRouter** WiFi from your phone/laptop
3. A captive portal will appear (or go to http://192.168.4.1)
4. Select the hotel WiFi network and enter password
5. If needed, complete the hotel's captive portal login
6. Click "Connect VPN"
7. Done! All your traffic is now encrypted

### Web Interface

Access the configuration portal at: **http://192.168.4.1**

- View connection status
- Scan and connect to WiFi networks
- Connect/disconnect VPN
- Access hotel captive portals

## Network Architecture

```
[Your Devices] --> [TravelRouter AP (wlan1)] --> [Raspberry Pi] --> [NordVPN] --> [Hotel WiFi (wlan0)] --> Internet
     ^                     ^                           ^
     |                     |                           |
   192.168.4.x        192.168.4.1                  VPN Tunnel
```

## Manual Commands

```bash
# Check status
nordvpn status
systemctl status vpn-ap

# Connect/disconnect VPN
nordvpn connect
nordvpn disconnect

# Restart services
sudo systemctl restart vpn-ap

# View connected clients
arp -a | grep 192.168.4

# Check public IP
curl https://api.ipify.org
```

## Troubleshooting

### Can't connect to AP
```bash
sudo systemctl status hostapd
sudo systemctl restart vpn-ap
```

### No internet through VPN
```bash
# Check VPN status
nordvpn status

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Check iptables
sudo iptables -t nat -L -n
```

### Lost SSH access
SSH should work via LAN discovery. If not:
```bash
# From a device on the AP network (192.168.4.x)
ssh pi@192.168.4.1
```

### Hotel captive portal not working
1. Disconnect VPN: `nordvpn disconnect`
2. Open http://neverssl.com in browser
3. Complete hotel login
4. Reconnect VPN: `nordvpn connect`

## Files

```
VPN-AP/
├── scripts/
│   ├── setup.sh              # Initial setup script
│   ├── start-ap.sh           # Start access point
│   ├── start-vpn.sh          # Start VPN with routing
│   ├── captive-portal.sh     # CLI captive portal bypass
│   ├── captive-portal-server.py  # Web configuration portal
│   └── switch-upstream.sh    # Switch between eth0/wlan0
├── config/
│   ├── hostapd.conf          # AP configuration
│   ├── dnsmasq.conf          # DHCP/DNS configuration
│   └── wg0.conf.template     # WireGuard template (optional)
└── systemd/
    ├── vpn-ap.service        # Main service
    └── captive-portal.service # Web portal service
```

## Security Notes

- Change the default AP password in `/etc/hostapd/hostapd.conf`
- NordVPN credentials are managed by the NordVPN CLI (not stored in config files)
- SSH access is preserved via LAN discovery and port allowlist
- Kill switch is handled by NordVPN's firewall

## License

MIT License

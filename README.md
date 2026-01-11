<p align="center">
  <img src="assets/logo.svg" alt="VPN-AP Logo" width="150" height="150">
</p>

<h1 align="center">VPN-AP: Travel VPN Router</h1>

<p align="center">
  Turn your Raspberry Pi into a portable VPN router.<br>
  Connect your devices to a secure WiFi access point that routes all traffic through NordVPN with a built-in kill switch.
</p>

---

## Why Use This?

**The Problem**: When traveling, you connect to untrusted networks (hotels, airports, cafes). Your traffic can be intercepted, and many networks block VPN apps or require captive portal logins that break VPN connections.

**The Solution**: VPN-AP creates a travel router that:

- **Protects all your devices** - Phones, laptops, tablets, even devices that can't run VPN apps (smart TVs, game consoles)
- **Handles captive portals gracefully** - Web interface to configure hotel WiFi and complete their login, then enable VPN
- **Guarantees protection with kill switch** - If VPN drops, traffic stops. No accidental exposure
- **Works everywhere** - Looks like a normal WiFi connection to your devices; no per-device VPN setup needed
- **Portable** - Raspberry Pi + USB WiFi adapter fits in your bag

**Use Cases**:
- Business travelers protecting sensitive work on hotel WiFi
- Privacy-conscious users who want all devices protected
- Families who want one VPN subscription to cover all devices
- Accessing geo-restricted content on devices that don't support VPN apps
- Security researchers who need a controlled network environment

## Features

- **Web-based Captive Portal**: Connect to the AP and configure WiFi through an intuitive web interface
- **NordVPN Integration**: Uses NordVPN CLI with NordLynx (WireGuard) protocol
- **Kill Switch**: If VPN disconnects, all client internet traffic stops (no leaks)
- **Hotel WiFi Support**: Easy captive portal bypass for hotel/airport networks
- **Auto-start on Boot**: Powers on in captive portal mode, ready to configure
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
7. Done! All your traffic is now encrypted with kill switch protection

### Web Interface

Access the configuration portal at: **http://192.168.4.1**

- View connection status (WiFi, VPN, Internet)
- Scan and connect to WiFi networks
- Connect/disconnect VPN
- Access hotel captive portals

## How It Works

### Boot Flow

```
Power On
    │
    ▼
┌─────────────────────────────────────┐
│  CAPTIVE PORTAL MODE                │
│  - DNS redirects all queries to Pi  │
│  - No internet forwarding           │
│  - Web portal at 192.168.4.1        │
└─────────────────────────────────────┘
    │
    │ User configures WiFi + connects VPN
    ▼
┌─────────────────────────────────────┐
│  VPN MODE (Kill Switch Active)      │
│  - Traffic only through VPN tunnel  │
│  - If VPN drops, internet stops     │
│  - Real DNS resolution enabled      │
└─────────────────────────────────────┘
    │
    │ Reboot/Power cycle
    ▼
    Back to Captive Portal Mode
```

### Network Architecture

```
[Your Devices] --> [TravelRouter AP (wlan1)] --> [Pi] --> [NordVPN] --> [Hotel WiFi (wlan0)] --> Internet
     ^                     ^                       ^
     |                     |                       |
   192.168.4.x        192.168.4.1            Kill Switch:
                                             Traffic ONLY
                                             through VPN
```

### Kill Switch

The kill switch ensures your traffic is always protected:

- **FORWARD rules** only allow `wlan1 ↔ nordlynx` (VPN interface)
- Direct forwarding `wlan1 ↔ wlan0` is **blocked**
- If VPN disconnects, client traffic has nowhere to go
- Pi can still reach upstream (to reconnect VPN)

## Manual Commands

```bash
# Check status
nordvpn status
systemctl status vpn-ap captive-portal

# Connect/disconnect VPN
nordvpn connect
nordvpn disconnect

# Manually apply firewall modes
sudo /usr/local/bin/iptables-vpn-mode.sh      # Kill switch mode
sudo /usr/local/bin/iptables-captive-mode.sh  # Captive portal mode

# Restart services
sudo systemctl restart vpn-ap
sudo systemctl restart captive-portal

# View connected clients
arp -a | grep 192.168.4

# Check public IP (should show VPN server IP)
curl https://api.ipify.org

# Check iptables rules
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v
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

# Check iptables (should show nordlynx rules)
sudo iptables -L FORWARD -n -v

# Re-apply VPN firewall
sudo /usr/local/bin/iptables-vpn-mode.sh
```

### Stuck in captive portal mode after VPN connects
```bash
# Remove DNS redirect manually
sudo rm /etc/dnsmasq.d/captive-portal.conf
sudo systemctl restart dnsmasq

# Apply VPN firewall
sudo /usr/local/bin/iptables-vpn-mode.sh
```

### Lost SSH access
SSH should work via LAN discovery. If not:
```bash
# From a device on the AP network (192.168.4.x)
ssh pi@192.168.4.1
```

### Hotel captive portal not working
1. Use the web portal's "Open Hotel Portal" button
2. Or manually: disconnect VPN, open http://neverssl.com, complete login, reconnect VPN

## Files

```
VPN-AP/
├── scripts/
│   ├── setup.sh                  # Initial setup script
│   ├── start-ap.sh               # Start access point
│   ├── start-vpn.sh              # Start VPN with routing
│   ├── captive-portal.sh         # CLI captive portal bypass
│   ├── captive-portal-server.py  # Web configuration portal
│   ├── switch-upstream.sh        # Switch between eth0/wlan0
│   ├── iptables-captive-mode.sh  # Restrictive firewall for portal mode
│   └── iptables-vpn-mode.sh      # Kill switch firewall for VPN mode
├── config/
│   ├── hostapd.conf              # AP configuration
│   ├── dnsmasq.conf              # DHCP/DNS configuration
│   ├── iptables.rules            # Legacy iptables rules
│   └── wg0.conf.template         # WireGuard template (optional)
├── systemd/
│   └── vpn-ap.service            # Main service
└── README.md
```

## Security Notes

- **Change the default AP password** in `/etc/hostapd/hostapd.conf`
- NordVPN credentials are managed by the NordVPN CLI (not stored in config files)
- SSH access is preserved via LAN discovery and port allowlist
- **Kill switch** ensures no traffic leaks if VPN disconnects
- Captive portal mode has restricted internet access (Pi only, not forwarded to clients)

## License

MIT License

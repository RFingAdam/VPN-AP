<p align="center">
  <img src="assets/logo.svg" alt="VPN-AP Logo" width="150" height="150">
</p>

<h1 align="center">VPN-AP: Travel VPN Router</h1>

<p align="center">
  Turn your Raspberry Pi into a portable, bulletproof VPN router.<br>
  Connect your devices to a secure WiFi access point that routes all traffic through NordVPN with a built-in kill switch.
</p>

<p align="center">
  <strong>Plug and play. Auto-recovery. Never get locked out.</strong>
</p>

---

## Why Use This?

**The Problem**: When traveling, you connect to untrusted networks (hotels, airports, cafes). Your traffic can be intercepted, and many networks block VPN apps or require captive portal logins that break VPN connections.

**The Solution**: VPN-AP creates a travel router that:

- **Protects all your devices** - Phones, laptops, tablets, even devices that can't run VPN apps (smart TVs, game consoles)
- **Handles captive portals gracefully** - Web interface to configure hotel WiFi and complete their login, then enable VPN
- **Guarantees protection with kill switch** - If VPN drops, traffic stops. No accidental exposure
- **Auto-recovers from failures** - Watchdog monitors services and reconnects automatically
- **Never locks you out** - SSH always accessible, emergency recovery built-in
- **Works everywhere** - Looks like a normal WiFi connection to your devices
- **Portable** - Raspberry Pi + USB WiFi adapter fits in your bag

## Features

### Core Features
- **Web-based Captive Portal** - Configure WiFi through an intuitive interface at `http://192.168.4.1`
- **NordVPN Integration** - Uses NordVPN CLI with NordLynx (WireGuard) protocol
- **Kill Switch** - If VPN disconnects, all client internet traffic stops (no leaks)
- **Hotel WiFi Support** - Easy captive portal bypass for hotel/airport networks
- **Dual Upstream Backhaul** - Ethernet preferred when available, WiFi fallback
- **HaLow (802.11ah) Support** - Optional long-range sub-GHz backhaul for remote deployments

### Reliability Features (v1.2.0+)
- **Automatic Watchdog** - Monitors services every minute, auto-recovers failures
- **WiFi Retry Logic** - 3 attempts with different strategies if connection fails
- **VPN Server Fallbacks** - Tries multiple servers (auto, US, UK, DE, NL, CH) if one fails
- **State Persistence** - Remembers last WiFi/VPN for auto-reconnect after reboot
- **Health Monitoring** - Background thread detects and fixes connection drops
- **Emergency Recovery** - Web-based and CLI recovery options

### Safety Features
- **SSH Always Accessible** - Port 22 open on ALL interfaces in all firewall modes
- **Portal Always Available** - Web interface at 192.168.4.1 always reachable
- **Graceful Degradation** - If VPN fails, internet still works (with warning)
- **Firewall Failsafes** - Management access rules inserted at top of iptables chains

## Hardware Requirements

- Raspberry Pi 4 (or Pi 3B+)
- USB WiFi adapter that supports AP mode (for the access point)
- Power supply
- MicroSD card (8GB+)
- *(Optional)* HaLow (802.11ah) module for long-range backhaul (e.g., Murata/Newracom, Morse Micro)

The built-in WiFi (`wlan0`) connects to upstream networks (hotel WiFi), while the USB adapter (`wlan1`) hosts the access point. For long-range deployments, a HaLow module can provide sub-GHz backhaul connectivity.

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
sudo systemctl enable vpn-ap-watchdog.timer
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
6. Click "Enable VPN"
7. Done! All your traffic is now encrypted with kill switch protection

### Web Interface

Access the configuration portal at: **http://192.168.4.1**

| Page | Description |
|------|-------------|
| `/` | Main dashboard - status and controls |
| `/scan` | Scan and connect to WiFi networks |
| `/vpn/connect` | Connect to VPN with retry logic |
| `/vpn/disconnect` | Disconnect VPN |
| `/hotel-portal` | Instructions for hotel captive portals |
| `/emergency` | Emergency recovery options |
| `/status` | JSON status for debugging |

### VPN modes

By default the system uses a WireGuard config at `/etc/wireguard/wg0.conf`.

To use NordVPN CLI (NordLynx):
- Set `VPN_MODE=nordvpn` and `VPN_INTERFACE=nordlynx` in `/etc/default/vpn-ap`
- Restart: `sudo systemctl restart vpn-ap`

You can also set `VPN_MODE=wireguard` (explicit) or `VPN_MODE=auto` to choose based on whether the `nordvpn` CLI is installed.
If your VPN uses a non-standard WireGuard port, set `VPN_ENDPOINT_PORT=XXXXX` in `/etc/default/vpn-ap`.

### Backhaul selection

By default the watchdog will restart the VPN if the default route changes (for example, when you plug in Ethernet).
The firewall allows DHCP/VPN on both `eth0` and `wlan0` so it can fail over safely.

To customize which upstream interfaces are allowed, set:
- `UPSTREAM_INTERFACES="eth0 wlan0"` in `/etc/default/vpn-ap`

### HaLow (802.11ah) Backhaul

VPN-AP supports HaLow (802.11ah) as an optional long-range backhaul for deployments where standard WiFi range is insufficient. HaLow operates on sub-GHz frequencies (~900 MHz) providing much greater range than 2.4/5 GHz WiFi.

**Requirements:**
- HaLow module (e.g., Murata with Newracom chipset, Morse Micro)
- Second Raspberry Pi with HaLow module running as AP at the internet-connected location

**Note:** HaLow is **manual-only** - it won't auto-select during failover. This is intentional because:
- HaLow has different latency/throughput characteristics than standard WiFi
- Sub-GHz frequencies have different regulatory requirements
- Driver loading may require explicit country code configuration

**Configuration** (in `/etc/default/vpn-ap`):

```bash
# Enable HaLow support
HALOW_ENABLED=1
HALOW_INTERFACE=wlan2              # HaLow interface name
HALOW_CONNECTION_METHOD=wpa_supplicant  # or nrc_start_py for Newracom SDK
HALOW_SSID="your-halow-ap"         # HaLow AP SSID
HALOW_PASSWORD="your-password"     # Network password
HALOW_SECURITY=sae                 # open, wpa2, or sae (WPA3)
HALOW_COUNTRY=US                   # Regulatory domain
NRC_PKG_PATH=/home/pi/nrc_pkg      # Newracom SDK path (if using nrc_start_py)
```

**Usage:**

```bash
# Check status (shows HaLow if enabled)
sudo vpn-ap-switch status

# Connect to HaLow backhaul
sudo vpn-ap-switch halow

# Disconnect from HaLow
sudo vpn-ap-switch halow-disconnect
```

**Typical HaLow Bridge Setup:**

```
[Internet] <--Ethernet--> [Pi #1 + HaLow AP] <~~HaLow 900MHz~~> [Pi #2 + HaLow STA] <--WiFi AP--> [Your Devices]
                                                 (long range)         (VPN-AP)
```

### Watchdog tuning

The watchdog runs every minute to keep the AP and VPN healthy.

- Settings live in `/etc/default/vpn-ap`
- Logs: `journalctl -u vpn-ap-watchdog`

### Emergency Recovery

If something goes wrong, you have multiple recovery options:

**Web-based** (from any device on TravelRouter WiFi):
```
http://192.168.4.1/emergency
```
- Reset Firewall (allow all traffic)
- Restart All Services
- Reconnect WiFi

**CLI-based** (via SSH):
```bash
# Full recovery - disconnect VPN, reset firewall, restart services
sudo vpn-ap-emergency full

# Just reset firewall to allow all
sudo vpn-ap-emergency reset

# Check current status
sudo vpn-ap-emergency status

# Disconnect VPN and reset firewall
sudo vpn-ap-emergency vpn-off
```

**SSH Access** - Always available on port 22:
```bash
ssh pi@192.168.4.1      # From TravelRouter network
ssh pi@<upstream-ip>    # From upstream network (hotel WiFi)
```

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
│  - Watchdog starts monitoring       │
└─────────────────────────────────────┘
    │
    │ User configures WiFi
    ▼
┌─────────────────────────────────────┐
│  INTERNET MODE (No VPN)             │
│  - Traffic forwarded (unencrypted!) │
│  - Warning shown in portal          │
│  - Can complete hotel login         │
└─────────────────────────────────────┘
    │
    │ User enables VPN
    ▼
┌─────────────────────────────────────┐
│  VPN MODE (Kill Switch Active)      │
│  - Traffic only through VPN tunnel  │
│  - If VPN drops, internet stops     │
│  - Auto-reconnect attempts          │
└─────────────────────────────────────┘
```

### Network Architecture

```
[Your Devices] --> [TravelRouter AP (wlan1)] --> [Pi] --> [NordVPN] --> [Upstream] --> Internet
     ^                     ^                       ^            ^            ^
     |                     |                       |            |            |
   192.168.4.x        192.168.4.1             Watchdog     Kill Switch   eth0 (Ethernet)
                                              monitors     Traffic ONLY   wlan0 (Hotel WiFi)
                                              & recovers   through VPN    HaLow (Long-range)
```

### Automatic Recovery

The system includes multiple layers of automatic recovery:

| Component | Recovery Mechanism |
|-----------|-------------------|
| **WiFi Connection** | 3 retry attempts with different strategies (normal → rescan → interface reset) |
| **VPN Connection** | Tries 6 different servers, 3 attempts each |
| **Services (hostapd, dnsmasq, portal)** | Watchdog checks every minute, auto-restarts if down |
| **WiFi Drops** | Health thread detects and reconnects to last known network |
| **VPN Drops** | Health thread detects and reconnects to last server |
| **Firewall Rules** | Management access rules re-added after every firewall change |

### Kill Switch

The kill switch ensures your traffic is always protected:

- **FORWARD rules** only allow `wlan1 ↔ nordlynx` (VPN interface)
- Direct forwarding `wlan1 ↔ wlan0` is **blocked**
- If VPN disconnects, client traffic has nowhere to go
- Pi can still reach upstream (to reconnect VPN)

## Manual Commands

### Status & Monitoring

```bash
# Check all services
systemctl status vpn-ap captive-portal hostapd dnsmasq

# Check VPN status
nordvpn status

# Check watchdog logs
cat /var/log/vpn-ap-watchdog.log

# Check portal logs
journalctl -u captive-portal -f

# View connected clients
arp -a | grep 192.168.4

# Check public IP (should show VPN server IP)
curl https://api.ipify.org
```

### VPN Control

```bash
# Connect/disconnect VPN
nordvpn connect
nordvpn disconnect

# Connect to specific server
nordvpn connect us
nordvpn connect uk
```
### Firewall Modes

```bash
# Apply VPN kill switch mode
sudo /usr/local/bin/iptables-vpn-mode.sh

# Apply internet mode (no VPN, forwarding enabled)
sudo /usr/local/bin/iptables-internet-mode.sh

# Apply captive portal mode (restrictive)
sudo /usr/local/bin/iptables-captive-mode.sh

# Check current rules
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v
```

### Service Control

```bash
# Restart services
sudo systemctl restart vpn-ap
sudo systemctl restart captive-portal
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq

# Run watchdog manually
sudo /usr/local/bin/vpn-ap-watchdog

# Check watchdog timer
systemctl list-timers vpn-ap-watchdog.timer
```

## Troubleshooting

### Can't connect to AP
```bash
sudo systemctl status hostapd
sudo systemctl restart vpn-ap
# Or use emergency recovery:
sudo vpn-ap-emergency restart
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

### Stuck in captive portal mode
```bash
# Remove DNS redirect manually
sudo rm /etc/dnsmasq.d/captive-portal.conf
sudo systemctl restart dnsmasq

# Apply internet or VPN firewall
sudo /usr/local/bin/iptables-internet-mode.sh
```

### Lost SSH access
SSH should always work. If having issues:
```bash
# From a device on the AP network (192.168.4.x)
ssh pi@192.168.4.1

# Emergency firewall reset (if you have console access)
sudo vpn-ap-emergency reset
```

### Hotel captive portal not working
1. Use the web portal's "Complete Hotel Login" button
2. Or manually: go to http://neverssl.com from portal, complete login

### Services keep crashing
```bash
# Check watchdog logs for recovery attempts
cat /var/log/vpn-ap-watchdog.log

# Check for errors
journalctl -u captive-portal -n 50
journalctl -u hostapd -n 50

# Full system recovery
sudo vpn-ap-emergency full
```

## Files

```
VPN-AP/
├── scripts/
│   ├── setup.sh                  # Initial setup script
│   ├── start-ap.sh               # Start access point
│   ├── start-vpn.sh              # Start VPN with routing
│   ├── captive-portal.sh         # CLI captive portal bypass
│   ├── captive-portal-server.py  # Web configuration portal (robust version)
│   ├── switch-upstream.sh        # Switch between eth0/wlan0/HaLow backhaul
│   ├── iptables-captive-mode.sh  # Restrictive firewall for portal mode
│   ├── iptables-internet-mode.sh # Forwarding without VPN
│   ├── iptables-vpn-mode.sh      # Kill switch firewall for VPN mode
│   ├── watchdog.sh               # Service monitor and auto-recovery
│   └── emergency-recovery.sh     # CLI emergency recovery tool
├── config/
│   ├── hostapd.conf              # AP configuration
│   ├── dnsmasq.conf              # DHCP/DNS configuration
│   ├── iptables.rules            # Legacy iptables rules
│   └── wg0.conf.template         # WireGuard template (optional)
├── systemd/
│   ├── vpn-ap.service            # Main AP service
│   ├── captive-portal.service    # Web portal service
│   ├── vpn-ap-watchdog.service   # Watchdog oneshot service
│   └── vpn-ap-watchdog.timer     # Watchdog timer (runs every minute)
├── README.md
└── CHANGELOG.md
```

## State Files

The system maintains state for recovery in `/var/lib/vpn-ap/`:

| File | Purpose |
|------|---------|
| `portal-state.json` | Last WiFi SSID/password, last VPN server |
| `last_watchdog_check` | Timestamp of last successful watchdog run |
| `*_recovery_count` | Tracks recovery attempts to prevent loops |
| `last_reset` | Date of last daily counter reset |

## Security Notes

- **Change the default AP password** in `/etc/hostapd/hostapd.conf`
- NordVPN credentials are managed by the NordVPN CLI (not stored in config files)
- SSH access is preserved via global iptables rule (port 22 always open)
- **Kill switch** ensures no traffic leaks if VPN disconnects
- Captive portal mode has restricted internet access (Pi only, not forwarded to clients)
- WiFi passwords are stored in state file for auto-reconnect (secured by file permissions)

## Reliability Guarantees

| Scenario | Behavior |
|----------|----------|
| WiFi connection fails | Retries 3x with different strategies, restores portal mode |
| VPN connection fails | Tries 6 servers, falls back to internet-only mode with warning |
| Service crashes | Watchdog restarts within 1 minute |
| Power loss / reboot | State restored, auto-reconnects to last WiFi/VPN |
| Firewall misconfiguration | Management access rules always re-added |
| Complete lockout | Emergency recovery via SSH or web portal |

## License

MIT License

# Changelog

All notable changes to VPN-AP will be documented in this file.

## [1.2.0] - 2026-01-11

### Added

#### Robustness & Auto-Recovery
- **Watchdog Service**: New systemd timer runs every minute to monitor and auto-recover services
  - Checks hostapd, dnsmasq, captive-portal health
  - Automatically restarts failed services
  - Ensures management access rules are always present
  - Logs to `/var/log/vpn-ap-watchdog.log`
  - Daily recovery count reset to prevent infinite loops

- **WiFi Connection Retry Logic**: 3 attempts with escalating strategies
  - Attempt 1: Normal connection
  - Attempt 2: Rescan networks + reconnect
  - Attempt 3: Interface reset + rescan + reconnect
  - On complete failure: automatically restores captive portal mode

- **VPN Server Fallbacks**: Tries multiple servers if connection fails
  - Server order: auto, US, UK, DE, NL, CH
  - 3 attempts per server before moving to next
  - Falls back to internet-only mode with warning if all fail

- **State Persistence**: System remembers configuration across reboots
  - Saves last successful WiFi SSID and password
  - Saves last successful VPN server
  - State stored in `/var/lib/vpn-ap/portal-state.json`
  - Auto-reconnects on service restart

- **Health Check Thread**: Background monitoring in portal server
  - Detects WiFi disconnection and attempts reconnect
  - Detects VPN disconnection and attempts reconnect
  - Ensures management access after every check

#### Emergency Recovery
- **Web-based Emergency Recovery** (`/emergency` endpoint)
  - Reset Firewall button (allows all traffic)
  - Restart All Services button
  - Reconnect WiFi link
  - Always accessible at http://192.168.4.1/emergency

- **CLI Emergency Recovery Tool** (`vpn-ap-emergency`)
  - `full`: Complete recovery - disconnect VPN, reset firewall, restart services
  - `reset`: Reset firewall to allow all traffic
  - `restart`: Restart AP services only
  - `status`: Show current system status
  - `vpn-off`: Disconnect VPN and reset firewall

#### Safety & Lockout Prevention
- **SSH Always Accessible**: Port 22 now open on ALL interfaces in all firewall modes
  - Removed interface-specific SSH rules
  - Added global SSH ACCEPT rule in all iptables scripts
  - Cannot lock yourself out via firewall misconfiguration

- **Management Access Enforcement**: `ensure_management_access()` function
  - Called after every firewall change
  - Inserts SSH, HTTP, DHCP, DNS rules at top of INPUT chain
  - Runs on portal startup and in health check thread

- **Graceful Degradation**: If VPN fails, internet still works
  - Shows warning in portal when connected without VPN
  - Users can choose to continue unprotected or retry VPN

### Changed
- **Captive Portal Server** completely rewritten for robustness
  - Threaded server for better responsiveness
  - All operations wrapped in try-except for error handling
  - Proper signal handling for graceful shutdown
  - Logging with timestamps

- **All iptables scripts** updated with safety comments
  - Added `# SAFETY: SSH is always allowed on ALL interfaces` header
  - Removed duplicate interface-specific SSH rules
  - Consistent structure across all three modes

- **Setup script** now installs all new components
  - Copies watchdog and emergency scripts
  - Installs watchdog timer and service
  - Creates state directory `/var/lib/vpn-ap`
  - Enables watchdog timer on install

### New Files
- `scripts/watchdog.sh` - Service monitor and auto-recovery
- `scripts/emergency-recovery.sh` - CLI emergency recovery tool
- `systemd/vpn-ap-watchdog.service` - Watchdog oneshot service
- `systemd/vpn-ap-watchdog.timer` - Watchdog timer (every minute)

### Security
- WiFi passwords stored in state file for auto-reconnect
- State file permissions set to root-only
- SSH access preserved regardless of firewall state

## [1.1.1] - 2026-01-11

### Fixed
- WiFi network switching now properly restores captive portal mode on failure
- SSID escaping in JavaScript handles backslashes correctly
- Prevents broken state when switching from one WiFi to another fails

## [1.1.0] - 2026-01-10

### Added
- **Kill Switch**: New iptables-based kill switch that blocks all client traffic if VPN disconnects
- **Two-mode firewall system**:
  - `iptables-captive-mode.sh`: Restrictive mode for initial setup (no internet forwarding)
  - `iptables-vpn-mode.sh`: VPN mode with kill switch (traffic only through VPN tunnel)
- **Internet Mode**: New `iptables-internet-mode.sh` for forwarding without VPN
- Automatic mode switching in captive portal:
  - Boot → Captive portal mode (DNS redirect, restricted firewall)
  - WiFi Connect → Internet mode (forwarding enabled, no VPN)
  - VPN Connect → VPN mode (kill switch active, real DNS)
  - VPN Disconnect → Internet mode (with warning)
- Updated web portal with kill switch status feedback

### Changed
- Captive portal server now manages firewall state transitions
- Improved boot flow documentation in README
- DNS redirect only active in captive portal mode (removed after WiFi connects)

### Security
- Client traffic cannot bypass VPN (FORWARD rules only allow wlan1 ↔ nordlynx)
- No direct forwarding between AP and upstream interfaces in VPN mode

## [1.0.0] - 2026-01-10

### Added
- Initial release
- Web-based captive portal for WiFi configuration
- NordVPN integration with NordLynx (WireGuard) protocol
- Hotel WiFi captive portal bypass support
- Automatic AP setup with hostapd and dnsmasq
- systemd services for auto-start
- SSH access preservation through VPN

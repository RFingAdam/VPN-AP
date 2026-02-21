# Changelog

All notable changes to VPN-AP will be documented in this file.

## [1.4.0] - 2026-02-21

### Fixed

#### Critical Reliability Fixes
- **Watchdog now recovers VPN failures** - Previously the watchdog only monitored AP services; VPN drops went undetected and unrecovered
- **Fixed infinite escalation loop** - Escalation counter was reset unconditionally, allowing infinite recovery loops. Now capped at 3 escalations/day and per-service counters only reset on successful escalation
- **Eliminated VPN recovery race condition** - Two independent systems (watchdog + portal health thread) could simultaneously try to reconnect WiFi/VPN, causing conflicts. Recovery is now consolidated into the watchdog only
- **Fixed DNS redirect race condition** - Firewall rules are now set up BEFORE removing DNS redirect during WiFi transitions (was reversed, causing brief traffic gaps)
- **Fixed management access rule duplication** - `ensure_management_access()` in both watchdog and portal now uses delete-before-insert pattern to prevent iptables rule accumulation

#### Firewall Safety
- **Atomic firewall transitions** - All three iptables scripts (`vpn-mode`, `internet-mode`, `captive-mode`) now use `iptables-restore` for atomic rule loading, eliminating the traffic gap between flush and rule creation where all traffic was dropped

### Added

#### VPN Health Monitoring
- **VPN health check** (`check_vpn_health()`) - Verifies VPN tunnel is actually passing traffic via ping, not just that the interface exists
- **VPN auto-recovery** (`recover_vpn()`) - Disconnects and reconnects VPN when health check fails, with retry limits
- **VPN signal file** (`vpn_should_be_active`) - Portal creates this on VPN connect, removes on disconnect. Watchdog uses it to know when VPN recovery is needed

#### WiFi Auto-Recovery
- **WiFi reconnect in watchdog** - Detects WiFi drops and reconnects to last known network using saved state

#### Exponential Backoff
- **Recovery backoff** - All recovery functions now apply exponential backoff (60s, 120s, 240s, 480s, 960s) between attempts to prevent rapid-fire recovery storms

#### Improved Health Checks
- **DNS resolution verification** - `check_dnsmasq()` now verifies DNS actually resolves (every 5th cycle) instead of just checking if the process is running
- **Upstream connectivity verification** - `check_upstream()` now pings 2 out of 3 DNS servers (8.8.8.8, 1.1.1.1, 9.9.9.9) instead of just checking interface state
- **Internet check reliability** - `get_status()` now uses 2-out-of-3 pings instead of a single ping to reduce false negatives

#### Captive Portal UX
- **Auto-detect hotel login completion** - Hotel portal page polls `/api/status` every 5 seconds and automatically shows success message with VPN button when internet is detected
- **User-friendly WiFi error messages** - Translates cryptic nmcli errors (e.g., "secrets were required" -> "Incorrect WiFi password. Please try again.")
- **Prominent captive portal banner** - When WiFi is connected but internet is unavailable, a large banner with direct hotel login link appears on the home page

#### Improved Log Rotation
- **3-file rotation** - Watchdog log now keeps 3 history files (`.old`, `.1`, `.2`) instead of 1, providing ~4MB of debug history

### Changed

#### systemd Service Hardening
- **captive-portal.service** - Added `StartLimitIntervalSec=300`, `StartLimitBurst=5` (stops after 5 crashes in 5 min), `TimeoutStopSec=10`
- **vpn-ap-watchdog.service** - Added `TimeoutStartSec=120` as hard backstop
- **vpn-ap.service** - Changed `StartLimitIntervalSec=0` (unlimited) to `StartLimitIntervalSec=600` with `StartLimitBurst=3`

#### Timeout Protection
- **Watchdog timeout wrappers** - All `systemctl` calls wrapped with 30s timeout (`sctl()`), all `iptables` calls wrapped with 10s timeout (`ipt()`), preventing the watchdog from hanging forever

#### Health Thread Consolidation
- **Portal health thread simplified** - No longer attempts WiFi/VPN reconnection (watchdog handles all recovery). Only monitors status and ensures management access

### State Files

New state files in `/var/lib/vpn-ap/`:

| File | Purpose |
|------|---------|
| `vpn_should_be_active` | Signal file: VPN was intentionally connected |
| `escalation_count` | Tracks full AP recovery escalation attempts |
| `*_last_recovery` | Timestamps for exponential backoff |

## [1.3.0] - 2026-01-19

### Added

#### HaLow (802.11ah) Backhaul Support
- **Long-range sub-GHz backhaul option** for remote deployments
  - Supports Newracom-based HaLow modules (e.g., Murata)
  - Operates on ~900 MHz for greater range than standard WiFi
  - Manual-only switching (not auto-selected during failover)

- **New switch-upstream.sh commands**:
  - `halow` - Connect to HaLow network as upstream backhaul
  - `halow-disconnect` - Disconnect from HaLow network
  - Status display now shows HaLow connection state when enabled

- **Dual connection methods**:
  - `wpa_supplicant` - Standard Linux wireless (default)
  - `nrc_start_py` - Newracom SDK for advanced features

- **HaLow configuration options** in `/etc/default/vpn-ap`:
  - `HALOW_ENABLED` - Enable/disable HaLow support
  - `HALOW_INTERFACE` - HaLow interface name (default: wlan2)
  - `HALOW_CONNECTION_METHOD` - wpa_supplicant or nrc_start_py
  - `HALOW_SSID` / `HALOW_PASSWORD` - Network credentials
  - `HALOW_SECURITY` - open, wpa2, or sae (WPA3)
  - `HALOW_COUNTRY` - Regulatory domain (US, EU, JP, etc.)
  - `NRC_PKG_PATH` - Path to Newracom SDK

- **Setup script enhancements**:
  - Auto-detects Newracom HaLow driver (nrc module)
  - Identifies HaLow interface during installation
  - Adds HaLow configuration template to defaults file

### Changed
- **Firewall scripts** now detect HaLow as upstream interface
  - `iptables-vpn-mode.sh` - HaLow upstream detection
  - `iptables-internet-mode.sh` - HaLow upstream detection
  - `iptables-captive-mode.sh` - HaLow upstream detection

### Design Notes
- HaLow intentionally excluded from `UPSTREAM_INTERFACES` auto-failover
- Requires explicit `vpn-ap-switch halow` command to activate
- Prevents unintended switching due to different latency/throughput characteristics

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

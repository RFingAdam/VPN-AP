# Changelog

All notable changes to VPN-AP will be documented in this file.

## [1.1.0] - 2026-01-10

### Added
- **Kill Switch**: New iptables-based kill switch that blocks all client traffic if VPN disconnects
- **Two-mode firewall system**:
  - `iptables-captive-mode.sh`: Restrictive mode for initial setup (no internet forwarding)
  - `iptables-vpn-mode.sh`: VPN mode with kill switch (traffic only through VPN tunnel)
- Automatic mode switching in captive portal:
  - Boot → Captive portal mode (DNS redirect, restricted firewall)
  - VPN Connect → VPN mode (kill switch active, real DNS)
  - VPN Disconnect → Back to captive portal mode
- Updated web portal with kill switch status feedback

### Changed
- Captive portal server now manages firewall state transitions
- Improved boot flow documentation in README
- DNS redirect only active in captive portal mode (removed after VPN connects)

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

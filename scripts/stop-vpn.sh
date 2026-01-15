#!/bin/bash
# Stop VPN in a provider-aware way.

set -e

VPN_MODE="${VPN_MODE:-auto}"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if [ "$VPN_MODE" = "auto" ]; then
    if command_exists nordvpn; then
        VPN_MODE="nordvpn"
    else
        VPN_MODE="wireguard"
    fi
fi

if [ "$VPN_MODE" = "nordvpn" ]; then
    if command_exists nordvpn; then
        nordvpn disconnect 2>/dev/null || true
    fi
else
    wg-quick down "$VPN_INTERFACE" 2>/dev/null || true
fi

#!/bin/bash
# VPN Mode - Kill switch that only allows traffic through VPN
# Called after VPN connects successfully
# SAFETY: SSH is always allowed on ALL interfaces to prevent lockout
# Uses iptables-restore for atomic rule loading (no traffic gap)

VPN_IF="${VPN_IF:-nordlynx}"
AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"

# AP_INTERFACES / AP_SUBNETS govern multi-AP mode (set by vpn-ap-mode). Fall
# back to the legacy single-AP values so old configs keep working unchanged.
AP_INTERFACES="${AP_INTERFACES:-$AP_IF}"
AP_SUBNETS="${AP_SUBNETS:-192.168.4.0/24}"

# Auto-detect VPN interface if nordlynx doesn't exist
if ! ip link show $VPN_IF &>/dev/null; then
    VPN_IF=$(ip link show | grep -oE "nordlynx[0-9]*|nordtun[0-9]*" | head -1)
    if [ -z "$VPN_IF" ]; then
        echo "ERROR: No VPN interface found! Is VPN connected?"
        exit 1
    fi
fi

# Source HaLow config if available
[ -f /etc/default/vpn-ap ] && . /etc/default/vpn-ap
HALOW_IF="${HALOW_INTERFACE:-wlan2}"

# Source shared upstream helper (select_upstream / upstream_iface_ready / ...)
_VPN_AP_LIB="${VPN_AP_LIB:-/usr/local/lib/vpn-ap}"
[ -r "$_VPN_AP_LIB/upstream.sh" ] || _VPN_AP_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
# shellcheck source=lib/upstream.sh
. "$_VPN_AP_LIB/upstream.sh"

# Extend candidates with HaLow only when explicitly enabled (preserves legacy fallback)
if [ "${HALOW_ENABLED:-0}" = "1" ] && [ -n "$HALOW_IF" ]; then
    case " $UPSTREAM_INTERFACES " in
        *" $HALOW_IF "*) ;;
        *) UPSTREAM_INTERFACES="$UPSTREAM_INTERFACES $HALOW_IF" ;;
    esac
fi

# Auto-detect upstream interface
DETECTED_UPSTREAM="$(select_upstream 2>/dev/null || true)"
if [ -n "$DETECTED_UPSTREAM" ]; then
    UPSTREAM_IF="$DETECTED_UPSTREAM"
    [ "$UPSTREAM_IF" = "$HALOW_IF" ] && echo "  Note: Using HaLow ($HALOW_IF) as upstream"
fi

echo "Setting up VPN kill switch mode..."
echo "  VPN Interface:    $VPN_IF"
echo "  AP Interfaces:    $AP_INTERFACES"
echo "  AP Subnets:       $AP_SUBNETS"
echo "  Upstream:         $UPSTREAM_IF"

# Build per-AP-interface filter rules
AP_FILTER_RULES=""
for _ap in $AP_INTERFACES; do
    AP_FILTER_RULES="$AP_FILTER_RULES
# --- AP interface: $_ap ---
-A INPUT -i $_ap -p udp --dport 67 -j ACCEPT
-A OUTPUT -o $_ap -p udp --sport 67 -j ACCEPT
-A INPUT -i $_ap -p udp --dport 53 -j ACCEPT
-A INPUT -i $_ap -p tcp --dport 53 -j ACCEPT
-A OUTPUT -o $_ap -p udp --sport 53 -j ACCEPT
-A OUTPUT -o $_ap -p tcp --sport 53 -j ACCEPT
-A INPUT -i $_ap -p tcp --dport 80 -j ACCEPT
-A INPUT -i $_ap -p icmp --icmp-type echo-request -j ACCEPT
-A OUTPUT -o $_ap -p icmp --icmp-type echo-reply -j ACCEPT
-A FORWARD -i $_ap -o $VPN_IF -j ACCEPT
-A FORWARD -i $VPN_IF -o $_ap -j ACCEPT"
done

# Build per-AP-subnet NAT rules
AP_NAT_RULES=""
for _subnet in $AP_SUBNETS; do
    AP_NAT_RULES="$AP_NAT_RULES
-A POSTROUTING -s $_subnet -o $VPN_IF -j MASQUERADE"
done

# Load all rules atomically via iptables-restore
iptables-restore <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# Allow loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === CRITICAL: SSH on ALL interfaces (prevent lockout) ===
-A INPUT -p tcp --dport 22 -j ACCEPT
-A OUTPUT -p tcp --sport 22 -j ACCEPT
$AP_FILTER_RULES

# === UPSTREAM RULES (minimal - only VPN tunnel) ===
-A OUTPUT -o $UPSTREAM_IF -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -i $UPSTREAM_IF -p udp --sport 67:68 --dport 67:68 -j ACCEPT
-A OUTPUT -o $UPSTREAM_IF -p udp -m conntrack --ctstate NEW -j ACCEPT

# === VPN INTERFACE RULES ===
-A INPUT -i $VPN_IF -j ACCEPT
-A OUTPUT -o $VPN_IF -j ACCEPT

# Clamp TCP MSS to path MTU (avoids PMTUD black holes on cellular/LTE uplinks)
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
$AP_NAT_RULES

COMMIT
RULES

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "VPN kill switch active - all traffic routed through VPN"
echo "If VPN disconnects, internet will stop (kill switch)"

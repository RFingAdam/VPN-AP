#!/bin/bash
# Captive Portal Mode - Restrictive iptables that only allows portal access
# Used on boot before VPN is connected
# SAFETY: SSH is always allowed on ALL interfaces to prevent lockout
# Uses iptables-restore for atomic rule loading (no traffic gap)

AP_IF="${AP_IF:-wlan1}"
UPSTREAM_IF="${UPSTREAM_IF:-wlan0}"
AP_IP="192.168.4.1"

# AP_INTERFACES / AP_SUBNETS govern multi-AP mode (set by vpn-ap-mode). Fall
# back to the legacy single-AP values so old configs keep working unchanged.
AP_INTERFACES="${AP_INTERFACES:-$AP_IF}"
AP_SUBNETS="${AP_SUBNETS:-192.168.4.0/24}"

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
[ -n "$DETECTED_UPSTREAM" ] && UPSTREAM_IF="$DETECTED_UPSTREAM"

echo "Setting up captive portal mode (restrictive)..."
echo "  AP Interfaces:    $AP_INTERFACES"
echo "  Upstream:         $UPSTREAM_IF"

# Build per-AP-interface filter rules (each AP gets portal access rights)
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
-A OUTPUT -o $_ap -p tcp --sport 80 -j ACCEPT
-A INPUT -i $_ap -p icmp --icmp-type echo-request -j ACCEPT
-A OUTPUT -o $_ap -p icmp --icmp-type echo-reply -j ACCEPT"
done

# PREROUTING DNAT to redirect AP clients' HTTP to the captive portal. The
# gateway IP on each AP interface is the first address of that subnet, so
# we pair AP_INTERFACES and AP_SUBNETS by position.
AP_DNAT_RULES=""
_ifaces_arr=($AP_INTERFACES)
_subnets_arr=($AP_SUBNETS)
for _i in "${!_ifaces_arr[@]}"; do
    _ap="${_ifaces_arr[$_i]}"
    _subnet="${_subnets_arr[$_i]:-${_subnets_arr[0]}}"
    # gateway IP = first usable in the /24 (x.x.x.1)
    _gw="$(echo "$_subnet" | awk -F/ '{print $1}' | awk -F. '{printf "%s.%s.%s.1", $1, $2, $3}')"
    AP_DNAT_RULES="$AP_DNAT_RULES
-A PREROUTING -i $_ap -p tcp --dport 80 -j DNAT --to-destination $_gw:80"
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

# Allow established connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === CRITICAL: SSH on ALL interfaces (prevent lockout) ===
-A INPUT -p tcp --dport 22 -j ACCEPT
-A OUTPUT -p tcp --sport 22 -j ACCEPT
$AP_FILTER_RULES

# === Upstream - Only allow what Pi needs to set up connection ===
-A OUTPUT -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -p udp --sport 67:68 --dport 67:68 -j ACCEPT
-A OUTPUT -p udp --dport 53 -j ACCEPT
-A OUTPUT -p tcp --dport 53 -j ACCEPT
-A OUTPUT -p tcp --dport 80 -j ACCEPT
-A OUTPUT -p tcp --dport 443 -j ACCEPT
-A OUTPUT -p udp -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
$AP_DNAT_RULES

COMMIT
RULES

echo "Captive portal mode active - no internet forwarding until VPN connects"

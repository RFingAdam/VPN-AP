#!/bin/bash
# One-shot iPhone USB-tether pairing helper.
# Installs usbmuxd/libimobiledevice, captures the iPhone's USB-tether MAC, and
# writes a udev rule aliasing that interface to `iphone0` so the rest of
# VPN-AP can use a stable name regardless of which iPhone is plugged in.
#
# Run once, at home, before your trip:
#   sudo scripts/setup-iphone-tether.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must be run as root (use sudo)${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
UDEV_RULE="/etc/udev/rules.d/70-iphone-tether.rules"

# Find the udev template. When setup.sh has been run it lives under
# /usr/local/lib/vpn-ap/udev-templates/; when running from the dev tree it
# lives alongside the project at $PROJECT_DIR/config/udev/.
UDEV_TEMPLATE=""
for candidate in \
    /usr/local/lib/vpn-ap/udev-templates/70-iphone-tether.rules.template \
    "$PROJECT_DIR/config/udev/70-iphone-tether.rules.template"; do
    if [ -r "$candidate" ]; then
        UDEV_TEMPLATE="$candidate"
        break
    fi
done

echo -e "${GREEN}VPN-AP iPhone USB-tether setup${NC}"
echo ""

# 0. Idempotency: if iphone0 is already present with a tether IP, this script
#    has been run before successfully. Exit early to avoid bouncing the
#    interface when usbmuxd is restarted later in the flow.
if [ -d /sys/class/net/iphone0 ]; then
    iphone0_brief=$(ip -4 -br addr show iphone0 2>/dev/null || true)
    case "$iphone0_brief" in
        *"172.20.10."*)
            echo -e "${GREEN}iphone0 already present with a 172.20.10.x lease — already set up.${NC}"
            echo "  $iphone0_brief"
            echo "  (nothing to do; udev rule at $UDEV_RULE still applies on next replug)"
            exit 0
            ;;
    esac
fi

# 1. Packages
need_install=0
for pkg in usbmuxd libimobiledevice-utils; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        need_install=1
        break
    fi
done
if [ "$need_install" -eq 1 ]; then
    echo "Installing usbmuxd and libimobiledevice-utils..."
    apt update
    apt install -y usbmuxd libimobiledevice-utils
fi

# 2. usbmuxd must be running for the tether interface to appear on iOS 17+
systemctl enable --now usbmuxd >/dev/null 2>&1 || true
if ! systemctl is-active --quiet usbmuxd; then
    echo -e "${RED}usbmuxd failed to start.${NC} Check: systemctl status usbmuxd"
    exit 1
fi

# If an iPhone is ALREADY plugged in at this point (common when the user
# installed usbmuxd after plugging the phone), usbmuxd's udev rule has
# already missed the ACTION=="add" event and /dev/bus/usb/<bus>/<dev> is
# still root-owned. Re-trigger udev and, as a safety net, chown any
# currently-present Apple USB device to the usbmux user.
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor=05ac --action=add 2>/dev/null || true
sleep 1
for dev in /sys/bus/usb/devices/*/idVendor; do
    [ -r "$dev" ] || continue
    if [ "$(cat "$dev" 2>/dev/null)" = "05ac" ]; then
        busnum=$(cat "$(dirname "$dev")/busnum" 2>/dev/null || echo)
        devnum=$(cat "$(dirname "$dev")/devnum" 2>/dev/null || echo)
        if [ -n "$busnum" ] && [ -n "$devnum" ]; then
            usbdev=$(printf "/dev/bus/usb/%03d/%03d" "$busnum" "$devnum")
            if [ -e "$usbdev" ]; then
                chown usbmux "$usbdev" 2>/dev/null || true
            fi
        fi
    fi
done
systemctl restart usbmuxd 2>/dev/null || true
sleep 1

# 3. Prompt user
echo ""
echo "Steps:"
echo "  1. Connect the iPhone to this Pi via a data-capable USB cable."
echo "  2. Unlock the iPhone and tap 'Trust' when prompted."
echo "  3. On the iPhone, turn ON Settings → Personal Hotspot."
echo ""
read -rp "Press Enter when the iPhone is connected, trusted, and hotspotting... " _

# 4. Find the iPhone interface. The ipheth driver names it enx<MAC> (stock
#    systemd naming) or eth1/usb0 on some kernels. Give it up to 30s to
#    show up (first-connect pairing is slow).
IPHETH_IF=""
for _i in $(seq 1 30); do
    for d in /sys/class/net/enx*; do
        [ -d "$d" ] || continue
        IPHETH_IF="$(basename "$d")"
        break
    done
    if [ -z "$IPHETH_IF" ]; then
        # Some kernels expose the tether as usb0 or eth1 when it's the only
        # USB-net device; match by driver name instead of glob. Exclude
        # iphone0 because we own that name — finding it here would mean
        # we're re-processing an already-set-up device.
        for cand in /sys/class/net/*; do
            cand_name=$(basename "$cand")
            [ "$cand_name" = "iphone0" ] && continue
            driver_path=$(readlink -f "$cand/device/driver" 2>/dev/null || true)
            case "$driver_path" in
                *ipheth*) IPHETH_IF="$cand_name"; break ;;
            esac
        done
    fi
    [ -n "$IPHETH_IF" ] && break
    sleep 1
done

if [ -z "$IPHETH_IF" ]; then
    echo -e "${RED}Could not find the iPhone USB-tether interface.${NC}"
    echo "Checks:"
    echo "  - lsusb | grep Apple       (iPhone should appear)"
    echo "  - dmesg | tail              (look for 'ipheth' messages)"
    echo "  - Trust dialog was accepted on the iPhone"
    echo "  - Personal Hotspot is ON and 'Allow Others to Join' is enabled"
    exit 1
fi

echo -e "${GREEN}Found iPhone tether interface:${NC} $IPHETH_IF"

# 5. Read the MAC (lowercase, colon-separated)
IPHONE_MAC=$(cat "/sys/class/net/$IPHETH_IF/address" 2>/dev/null || true)
if [ -z "$IPHONE_MAC" ]; then
    echo -e "${RED}Could not read MAC address of $IPHETH_IF${NC}"
    exit 1
fi
echo "  MAC: $IPHONE_MAC"

# 6. Install the udev rule
if [ -z "$UDEV_TEMPLATE" ] || [ ! -f "$UDEV_TEMPLATE" ]; then
    echo -e "${RED}Udev template not found in any of the expected locations.${NC}"
    echo "  Did you run scripts/setup.sh first? It installs the template to"
    echo "  /usr/local/lib/vpn-ap/udev-templates/."
    exit 1
fi
sed "s/{{IPHONE_MAC}}/$IPHONE_MAC/g" "$UDEV_TEMPLATE" > "$UDEV_RULE"
chmod 644 "$UDEV_RULE"
echo "Installed udev rule: $UDEV_RULE (from template $UDEV_TEMPLATE)"

# 7. Apply it. If the interface is already named enx..., we need to bring it
#    down and trigger udev to rename; simplest is to ask the user to re-plug.
udevadm control --reload-rules
udevadm trigger --subsystem-match=net --action=add

sleep 2
if [ -d /sys/class/net/iphone0 ]; then
    echo -e "${GREEN}iphone0 is present.${NC}"
else
    echo -e "${YELLOW}udev did not rename in place. Unplug and re-plug the iPhone, then run:${NC}"
    echo "  ip -4 addr show iphone0"
fi

# 8. Verify
echo ""
echo "Verification (may take a moment after re-plug):"
if ip -4 addr show iphone0 2>/dev/null | grep -q "inet "; then
    IPHONE_IP=$(ip -4 addr show iphone0 | awk '/inet /{print $2; exit}')
    echo -e "  ${GREEN}iphone0 has IP: $IPHONE_IP${NC}"
    echo "  (iPhone DHCP typically hands out 172.20.10.x/28)"
else
    echo -e "  ${YELLOW}iphone0 has no IPv4 address yet.${NC}"
    echo "  After re-plugging, check: ip -4 addr show iphone0"
fi

echo ""
echo -e "${GREEN}Done.${NC}"
echo "Next: ensure /etc/default/vpn-ap has iphone0 in UPSTREAM_INTERFACES."
echo "Recommended: UPSTREAM_INTERFACES=\"iphone0 eth0 wlan0\""

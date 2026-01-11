#!/usr/bin/env python3
"""
VPN-AP Captive Portal Server - Robust Version
A resilient web server for WiFi and VPN configuration with multiple fallbacks

Features:
- WiFi connection with retries and recovery
- VPN connection with server fallbacks
- State persistence for recovery after crashes
- Health monitoring and self-healing
- Graceful degradation (VPN fails -> internet mode -> captive mode)
- Management access always preserved
"""

import http.server
import socketserver
import subprocess
import json
import urllib.parse
import os
import threading
import time
import html
import signal
import sys

PORT = 80
AP_IP = "192.168.4.1"
STATE_FILE = "/var/lib/vpn-ap/portal-state.json"
STATE_DIR = "/var/lib/vpn-ap"

# Retry configuration
WIFI_MAX_RETRIES = 3
WIFI_RETRY_DELAY = 5
VPN_MAX_RETRIES = 3
VPN_RETRY_DELAY = 5
VPN_SERVERS = ["", "us", "uk", "de", "nl", "ch"]  # Empty = auto, then specific countries

# Ensure state directory exists
os.makedirs(STATE_DIR, exist_ok=True)

HTML_HEADER = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPN Router Setup</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
               background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
               min-height: 100vh; color: #fff; padding: 20px; }
        .container { max-width: 500px; margin: 0 auto; }
        h1 { text-align: center; margin-bottom: 30px; font-size: 24px; }
        .card { background: rgba(255,255,255,0.1); border-radius: 12px;
                padding: 20px; margin-bottom: 20px; backdrop-filter: blur(10px); }
        .card h2 { font-size: 18px; margin-bottom: 15px; color: #4ecca3; }
        .status { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
        .status-dot { width: 12px; height: 12px; border-radius: 50%; }
        .status-dot.green { background: #4ecca3; }
        .status-dot.yellow { background: #ffc107; }
        .status-dot.red { background: #dc3545; }
        .network-list { list-style: none; max-height: 200px; overflow-y: auto; }
        .network-item { padding: 12px; margin: 8px 0; background: rgba(255,255,255,0.05);
                        border-radius: 8px; cursor: pointer; transition: all 0.2s; }
        .network-item:hover { background: rgba(78, 204, 163, 0.2); }
        .network-item.selected { background: rgba(78, 204, 163, 0.3); border: 1px solid #4ecca3; }
        .signal { float: right; opacity: 0.7; }
        input[type="text"], input[type="password"] {
            width: 100%; padding: 12px; border: none; border-radius: 8px;
            background: rgba(255,255,255,0.1); color: #fff; font-size: 16px;
            margin-bottom: 15px; }
        input::placeholder { color: rgba(255,255,255,0.5); }
        button { width: 100%; padding: 14px; border: none; border-radius: 8px;
                 background: #4ecca3; color: #1a1a2e; font-size: 16px;
                 font-weight: 600; cursor: pointer; transition: all 0.2s; }
        button:hover { background: #3db892; transform: translateY(-2px); }
        button:disabled { background: #666; cursor: not-allowed; transform: none; }
        button.secondary { background: rgba(255,255,255,0.1); color: #fff; margin-top: 10px; }
        button.danger { background: #dc3545; color: #fff; margin-top: 10px; }
        .message { padding: 15px; border-radius: 8px; margin-bottom: 15px; }
        .message.success { background: rgba(78, 204, 163, 0.2); border: 1px solid #4ecca3; }
        .message.error { background: rgba(220, 53, 69, 0.2); border: 1px solid #dc3545; }
        .message.info { background: rgba(255, 193, 7, 0.2); border: 1px solid #ffc107; }
        .message.warning { background: rgba(255, 152, 0, 0.2); border: 1px solid #ff9800; }
        .loading { text-align: center; padding: 20px; }
        .spinner { display: inline-block; width: 30px; height: 30px;
                   border: 3px solid rgba(255,255,255,0.3);
                   border-radius: 50%; border-top-color: #4ecca3;
                   animation: spin 1s ease-in-out infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }
        a { color: #4ecca3; text-decoration: none; }
        .retry-info { font-size: 12px; opacity: 0.7; margin-top: 5px; }
    </style>
</head>
<body>
<div class="container">
"""

HTML_FOOTER = """
</div>
</body>
</html>
"""


def log(msg):
    """Log with timestamp"""
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}")


def run_cmd(cmd, timeout=30):
    """Run a shell command and return output"""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True,
                                text=True, timeout=timeout)
        return result.stdout.strip(), result.returncode
    except subprocess.TimeoutExpired:
        log(f"Command timed out: {cmd[:50]}...")
        return "Command timed out", 1
    except Exception as e:
        log(f"Command failed: {e}")
        return str(e), 1


def save_state(state):
    """Save state to disk for recovery"""
    try:
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
    except Exception as e:
        log(f"Failed to save state: {e}")


def load_state():
    """Load state from disk"""
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
    except Exception as e:
        log(f"Failed to load state: {e}")
    return {}


def ensure_management_access():
    """CRITICAL: Ensure SSH and portal access is never blocked"""
    ap_if = os.environ.get('AP_IF', 'wlan1')

    cmds = [
        # Always allow SSH on all interfaces
        "iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT",
        # Always allow portal HTTP on AP
        f"iptables -C INPUT -i {ap_if} -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -i {ap_if} -p tcp --dport 80 -j ACCEPT",
        # Always allow DHCP on AP
        f"iptables -C INPUT -i {ap_if} -p udp --dport 67 -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i {ap_if} -p udp --dport 67 -j ACCEPT",
        # Always allow DNS on AP
        f"iptables -C INPUT -i {ap_if} -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -i {ap_if} -p udp --dport 53 -j ACCEPT",
        # Allow loopback
        "iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT",
    ]

    for cmd in cmds:
        run_cmd(cmd)


def get_wifi_networks():
    """Scan for available WiFi networks with retry"""
    for attempt in range(2):
        networks = []
        output, code = run_cmd("nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan yes 2>/dev/null", timeout=20)
        if code == 0 and output:
            seen = set()
            for line in output.split('\n'):
                parts = line.split(':')
                if len(parts) >= 2 and parts[0] and parts[0] not in seen:
                    seen.add(parts[0])
                    networks.append({
                        'ssid': parts[0],
                        'signal': parts[1] if len(parts) > 1 else '?',
                        'security': parts[2] if len(parts) > 2 else ''
                    })
            if networks:
                return networks
        time.sleep(2)
    return []


def get_status():
    """Get current connection status"""
    status = {
        'wifi_connected': False,
        'wifi_ssid': '',
        'wifi_ip': '',
        'vpn_connected': False,
        'vpn_ip': '',
        'vpn_server': '',
        'internet': False,
        'mode': 'unknown'
    }

    # Check WiFi connection on wlan0 (upstream)
    output, code = run_cmd("nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION dev show wlan0 2>/dev/null")
    if 'connected' in output.lower():
        status['wifi_connected'] = True
        # Get SSID
        ssid_out, _ = run_cmd("iwconfig wlan0 2>/dev/null | grep ESSID | sed 's/.*ESSID:\"\\([^\"]*\\)\".*/\\1/'")
        status['wifi_ssid'] = ssid_out
        # Get IP
        ip_out, _ = run_cmd("ip addr show wlan0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
        status['wifi_ip'] = ip_out

    # Check VPN
    vpn_out, code = run_cmd("nordvpn status 2>/dev/null")
    if 'Connected' in vpn_out:
        status['vpn_connected'] = True
        # Get server info
        for line in vpn_out.split('\n'):
            if 'Server:' in line or 'City:' in line:
                status['vpn_server'] = line.split(':', 1)[-1].strip()
                break
        # Get VPN IP (with short timeout to avoid blocking)
        ip_match = run_cmd("curl -s --max-time 3 https://api.ipify.org 2>/dev/null")
        status['vpn_ip'] = ip_match[0] if ip_match[1] == 0 else ''

    # Check internet (quick ping test)
    _, code = run_cmd("ping -c 1 -W 2 8.8.8.8 2>/dev/null")
    status['internet'] = (code == 0)

    # Determine current mode
    if status['vpn_connected']:
        status['mode'] = 'vpn'
    elif status['wifi_connected'] and status['internet']:
        status['mode'] = 'internet'
    elif status['wifi_connected']:
        status['mode'] = 'captive_portal_needed'
    else:
        status['mode'] = 'captive'

    return status


def run_cmd_safe(args, timeout=30):
    """Run a command with argument list (no shell injection risk)"""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip(), result.returncode, result.stderr.strip()
    except subprocess.TimeoutExpired:
        log(f"Command timed out: {args[0]}")
        return "Command timed out", 1, ""
    except Exception as e:
        log(f"Command failed: {e}")
        return str(e), 1, ""


def delete_wifi_connection(ssid):
    """Delete existing NetworkManager connection profile for SSID"""
    # List all connections and find ones matching this SSID
    output, code = run_cmd("nmcli -t -f NAME,TYPE connection show")
    if code == 0:
        for line in output.split('\n'):
            if ':802-11-wireless' in line or ':wifi' in line:
                conn_name = line.split(':')[0]
                # Check if this connection is for our SSID
                check_out, check_code = run_cmd(f"nmcli -t -f 802-11-wireless.ssid connection show '{conn_name}' 2>/dev/null")
                if check_code == 0 and ssid in check_out:
                    log(f"Deleting old connection profile: {conn_name}")
                    run_cmd(f"nmcli connection delete '{conn_name}' 2>/dev/null")

    # Also try deleting by exact SSID name (common naming convention)
    run_cmd(f"nmcli connection delete id '{ssid}' 2>/dev/null")


def connect_wifi_nmcli(ssid, password):
    """Connect to WiFi using nmcli with proper argument handling"""
    # Build the command as a list to avoid shell escaping issues
    if password:
        args = [
            'nmcli', 'dev', 'wifi', 'connect', ssid,
            'password', password,
            'ifname', 'wlan0'
        ]
    else:
        args = [
            'nmcli', 'dev', 'wifi', 'connect', ssid,
            'ifname', 'wlan0'
        ]

    stdout, code, stderr = run_cmd_safe(args, timeout=45)

    if code == 0:
        return True, stdout
    else:
        error_msg = stderr if stderr else stdout
        return False, error_msg


def connect_wifi_with_retry(ssid, password, max_retries=WIFI_MAX_RETRIES):
    """Connect to WiFi with multiple retry strategies"""
    log(f"Attempting to connect to WiFi: {ssid}")

    # Save current connection info in case we need to restore
    current_ssid, _ = run_cmd("iwconfig wlan0 2>/dev/null | grep ESSID | sed 's/.*ESSID:\"\\([^\"]*\\)\".*/\\1/'")

    for attempt in range(max_retries):
        log(f"WiFi connection attempt {attempt + 1}/{max_retries}")

        # Disconnect current connection first
        run_cmd("nmcli dev disconnect wlan0 2>/dev/null")
        time.sleep(1)

        # On first attempt or after failures, clean up old connection profiles
        if attempt == 0:
            # Delete any existing connection profiles for this SSID to start fresh
            delete_wifi_connection(ssid)
            time.sleep(1)

        # Different strategies per attempt
        if attempt == 1:
            # Second attempt: Force rescan
            log("Forcing network rescan...")
            run_cmd("nmcli dev wifi rescan 2>/dev/null")
            time.sleep(3)
        elif attempt >= 2:
            # Third attempt: Reset interface completely
            log("Resetting WiFi interface...")
            run_cmd("nmcli radio wifi off")
            time.sleep(2)
            run_cmd("nmcli radio wifi on")
            time.sleep(3)
            run_cmd("nmcli dev wifi rescan 2>/dev/null")
            time.sleep(2)

        # Connect using safe argument passing (no shell escaping issues)
        success, output = connect_wifi_nmcli(ssid, password)

        if success:
            log(f"WiFi connection command successful for {ssid}")
            # Wait for IP assignment
            time.sleep(3)

            # Verify we got an IP
            ip_out, _ = run_cmd("ip addr show wlan0 | grep 'inet '")
            if ip_out:
                log(f"WiFi connected successfully to {ssid} with IP")
                # Save successful connection info
                save_state({'last_wifi_ssid': ssid, 'last_wifi_password': password})

                # Enable internet mode
                remove_dns_redirect()
                setup_internet_mode_firewall()
                ensure_management_access()
                return True, "Connected successfully"
            else:
                log("Connected but no IP received, retrying...")
        else:
            log(f"Connection attempt failed: {output}")

        if attempt < max_retries - 1:
            time.sleep(WIFI_RETRY_DELAY)

    # All attempts failed - restore captive portal mode
    log(f"All WiFi connection attempts failed for {ssid}")
    setup_dns_redirect()
    setup_captive_mode_firewall()
    ensure_management_access()

    return False, "Connection failed after multiple attempts"


def connect_vpn_with_retry(max_retries=VPN_MAX_RETRIES):
    """Connect to VPN with server fallbacks"""
    log("Attempting to connect to VPN...")

    for server_idx, server in enumerate(VPN_SERVERS):
        for attempt in range(max_retries):
            server_name = server if server else "auto"
            log(f"VPN connection attempt: server={server_name}, attempt={attempt + 1}/{max_retries}")

            if server:
                cmd = f"nordvpn connect {server}"
            else:
                cmd = "nordvpn connect"

            output, code = run_cmd(cmd, timeout=30)

            if code == 0 or "You are connected" in output or "Already connected" in output:
                time.sleep(3)  # Wait for interface

                # Verify VPN is actually connected
                status_out, _ = run_cmd("nordvpn status 2>/dev/null")
                if 'Connected' in status_out:
                    log(f"VPN connected successfully to {server_name}")

                    # Save successful server
                    save_state({'last_vpn_server': server})

                    # Set up kill switch
                    if setup_vpn_mode_firewall():
                        ensure_management_access()
                        return True, f"Connected to VPN ({server_name})"
                    else:
                        log("VPN connected but kill switch failed, staying in internet mode")
                        return True, "Connected (kill switch failed)"

            log(f"VPN attempt failed: {output}")
            if attempt < max_retries - 1:
                time.sleep(VPN_RETRY_DELAY)

        # Try next server
        if server_idx < len(VPN_SERVERS) - 1:
            log(f"Trying next VPN server...")

    log("All VPN connection attempts failed")
    return False, "VPN connection failed after trying multiple servers"


def disconnect_vpn():
    """Disconnect from NordVPN safely"""
    output, code = run_cmd("nordvpn disconnect", timeout=10)
    time.sleep(1)

    # Switch to internet mode (not captive, since WiFi should still work)
    setup_internet_mode_firewall()
    ensure_management_access()

    return code == 0, output


def setup_dns_redirect():
    """Set up DNS to redirect all requests to captive portal"""
    dnsmasq_conf = "/etc/dnsmasq.d/captive-portal.conf"
    try:
        with open(dnsmasq_conf, 'w') as f:
            f.write(f"address=/#/{AP_IP}\n")
        subprocess.run(["systemctl", "restart", "dnsmasq"], check=False, timeout=10)
        log("DNS redirect enabled")
    except Exception as e:
        log(f"Warning: Could not configure DNS redirect: {e}")


def remove_dns_redirect():
    """Remove captive portal DNS redirect"""
    dnsmasq_conf = "/etc/dnsmasq.d/captive-portal.conf"
    try:
        if os.path.exists(dnsmasq_conf):
            os.remove(dnsmasq_conf)
        subprocess.run(["systemctl", "restart", "dnsmasq"], check=False, timeout=10)
        log("DNS redirect removed")
    except Exception as e:
        log(f"Warning: Could not remove DNS redirect: {e}")


def find_script(name):
    """Find script in known locations"""
    paths = [
        f"/usr/local/bin/{name}",
        f"/home/pi/VPN-AP/scripts/{name}",
    ]
    for p in paths:
        if os.path.exists(p):
            return p
    return None


def setup_captive_mode_firewall():
    """Set up restrictive firewall for captive portal mode"""
    script = find_script("iptables-captive-mode.sh")
    if script:
        result = subprocess.run(["bash", script], capture_output=True, text=True)
        ensure_management_access()  # Always ensure access after firewall change
        log("Captive mode firewall activated")
        return result.returncode == 0
    else:
        log("Warning: iptables-captive-mode.sh not found")
        return False


def setup_internet_mode_firewall():
    """Set up firewall that allows internet without VPN"""
    script = find_script("iptables-internet-mode.sh")
    if script:
        result = subprocess.run(["bash", script], capture_output=True, text=True)
        ensure_management_access()  # Always ensure access after firewall change
        if result.returncode == 0:
            log("Internet mode firewall activated")
            return True
        else:
            log(f"Failed to set up internet firewall: {result.stderr}")
            return False
    else:
        log("Warning: iptables-internet-mode.sh not found")
        return False


def setup_vpn_mode_firewall():
    """Set up VPN kill switch firewall"""
    script = find_script("iptables-vpn-mode.sh")
    if script:
        result = subprocess.run(["bash", script], capture_output=True, text=True)
        ensure_management_access()  # Always ensure access after firewall change
        if result.returncode == 0:
            log("VPN kill switch firewall activated")
            return True
        else:
            log(f"Failed to set up VPN firewall: {result.stderr}")
            return False
    else:
        log("Warning: iptables-vpn-mode.sh not found")
        return False


def reconnect_last_wifi():
    """Try to reconnect to last known WiFi"""
    state = load_state()
    ssid = state.get('last_wifi_ssid')
    password = state.get('last_wifi_password', '')

    if ssid:
        log(f"Attempting to reconnect to last WiFi: {ssid}")
        success, _ = connect_wifi_with_retry(ssid, password, max_retries=2)
        return success
    return False


def reconnect_last_vpn():
    """Try to reconnect to last known VPN server"""
    state = load_state()
    server = state.get('last_vpn_server', '')

    if server:
        log(f"Attempting to reconnect to last VPN server: {server}")
        cmd = f"nordvpn connect {server}" if server else "nordvpn connect"
        output, code = run_cmd(cmd, timeout=30)
        if code == 0:
            time.sleep(2)
            setup_vpn_mode_firewall()
            ensure_management_access()
            return True
    return False


class CaptivePortalHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress HTTP logging

    def send_html(self, content, status=200):
        try:
            self.send_response(status)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
            self.end_headers()
            self.wfile.write((HTML_HEADER + content + HTML_FOOTER).encode())
        except Exception as e:
            log(f"Error sending HTML: {e}")

    def send_json(self, data, status=200):
        try:
            self.send_response(status)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())
        except Exception as e:
            log(f"Error sending JSON: {e}")

    def redirect(self, url):
        try:
            self.send_response(302)
            self.send_header('Location', url)
            self.end_headers()
        except Exception as e:
            log(f"Error redirecting: {e}")

    def do_GET(self):
        try:
            path = urllib.parse.urlparse(self.path).path

            # Captive portal detection endpoints - redirect to our portal
            if path in ['/generate_204', '/gen_204', '/hotspot-detect.html',
                        '/library/test/success.html', '/success.txt', '/ncsi.txt',
                        '/connecttest.txt', '/redirect', '/canonical.html']:
                self.redirect(f'http://{AP_IP}/')
                return

            if path == '/':
                self.show_home()
            elif path == '/scan':
                self.show_scan()
            elif path == '/status':
                self.show_status()
            elif path == '/api/status':
                self.send_json(get_status())
            elif path == '/api/networks':
                self.send_json(get_wifi_networks())
            elif path == '/vpn/connect':
                self.vpn_action('connect')
            elif path == '/vpn/disconnect':
                self.vpn_action('disconnect')
            elif path == '/hotel-portal':
                self.show_hotel_portal()
            elif path == '/emergency':
                self.show_emergency()
            elif path == '/emergency/reset-firewall':
                self.emergency_reset_firewall()
            elif path == '/emergency/restart-services':
                self.emergency_restart_services()
            else:
                # Unknown path - redirect to home (captive portal behavior)
                self.redirect(f'http://{AP_IP}/')
        except Exception as e:
            log(f"Error handling GET {self.path}: {e}")
            self.send_html(f'<h1>Error</h1><p>{html.escape(str(e))}</p><a href="/"><button>Home</button></a>', 500)

    def do_POST(self):
        try:
            path = urllib.parse.urlparse(self.path).path
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length).decode('utf-8')
            params = urllib.parse.parse_qs(post_data)

            if path == '/connect':
                ssid = params.get('ssid', [''])[0]
                password = params.get('password', [''])[0]
                self.handle_connect(ssid, password)
            else:
                self.redirect('/')
        except Exception as e:
            log(f"Error handling POST {self.path}: {e}")
            self.send_html(f'<h1>Error</h1><p>{html.escape(str(e))}</p><a href="/"><button>Home</button></a>', 500)

    def show_home(self):
        status = get_status()

        content = '<h1>VPN Router</h1>'

        # Status card
        content += '<div class="card"><h2>Status</h2>'

        # WiFi status
        if status['wifi_connected']:
            content += f'''<div class="status">
                <span class="status-dot green"></span>
                <span>WiFi: {html.escape(status['wifi_ssid'])}</span>
            </div>'''
        else:
            content += '''<div class="status">
                <span class="status-dot red"></span>
                <span>WiFi: Not connected</span>
            </div>'''

        # VPN status
        if status['vpn_connected']:
            server_info = f" ({status['vpn_server']})" if status['vpn_server'] else ""
            ip_info = f" - {status['vpn_ip']}" if status['vpn_ip'] else ""
            content += f'''<div class="status">
                <span class="status-dot green"></span>
                <span>VPN: Connected{server_info}{ip_info}</span>
            </div>'''
        else:
            content += '''<div class="status">
                <span class="status-dot yellow"></span>
                <span>VPN: Off</span>
            </div>'''

        # Internet status
        if status['internet']:
            content += '''<div class="status">
                <span class="status-dot green"></span>
                <span>Internet: OK</span>
            </div>'''
        else:
            content += '''<div class="status">
                <span class="status-dot red"></span>
                <span>Internet: No connection</span>
            </div>'''

        content += '</div>'

        # Warning if connected without VPN
        if status['wifi_connected'] and status['internet'] and not status['vpn_connected']:
            content += '''<div class="message warning">
                Traffic is NOT encrypted. Enable VPN for protection.
            </div>'''

        # Actions
        content += '<div class="card"><h2>Controls</h2>'

        # WiFi button
        content += '<a href="/scan"><button>Select WiFi Network</button></a>'

        # Show hotel portal button if WiFi connected but no internet
        if status['wifi_connected'] and not status['internet']:
            content += '<a href="/hotel-portal"><button class="secondary">Complete Hotel Login</button></a>'

        # VPN controls - show if WiFi is connected
        if status['wifi_connected']:
            if status['vpn_connected']:
                content += '<a href="/vpn/disconnect"><button class="danger">Disable VPN</button></a>'
            else:
                content += '<a href="/vpn/connect"><button class="secondary">Enable VPN</button></a>'

        # Emergency link
        content += '<a href="/emergency"><button class="secondary" style="margin-top: 20px; font-size: 12px;">Emergency Recovery</button></a>'

        content += '</div>'

        self.send_html(content)

    def show_scan(self):
        content = '<h1>Select WiFi</h1>'
        content += '<div class="card">'
        content += '<div class="loading"><div class="spinner"></div><p>Scanning...</p></div>'
        content += '''
        <script>
        fetch('/api/networks')
            .then(r => r.json())
            .then(networks => {
                let html = '<form method="POST" action="/connect">';
                html += '<ul class="network-list">';
                if (networks.length === 0) {
                    html += '<li class="network-item">No networks found. Try again.</li>';
                }
                networks.forEach(n => {
                    const ssidEsc = n.ssid.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'").replace(/"/g, "&quot;");
                    html += '<li class="network-item" onclick="selectNetwork(this, \\'' + ssidEsc + '\\')">';
                    html += n.ssid + ' <span class="signal">' + n.signal + '% ' + (n.security ? '🔒' : '') + '</span>';
                    html += '</li>';
                });
                html += '</ul>';
                html += '<input type="hidden" name="ssid" id="ssid">';
                html += '<input type="password" name="password" placeholder="Password (if required)">';
                html += '<button type="submit">Connect</button>';
                html += '</form>';
                html += '<a href="/"><button class="secondary">Cancel</button></a>';
                document.querySelector('.card').innerHTML = html;
            })
            .catch(err => {
                document.querySelector('.card').innerHTML = '<p>Error scanning networks. <a href="/scan">Retry</a></p>';
            });
        function selectNetwork(el, ssid) {
            document.querySelectorAll('.network-item').forEach(e => e.classList.remove('selected'));
            el.classList.add('selected');
            document.getElementById('ssid').value = ssid;
        }
        </script>
        '''
        content += '</div>'
        self.send_html(content)

    def handle_connect(self, ssid, password):
        content = '<h1>Connecting...</h1>'
        content += '<div class="card">'
        content += f'<p>Connecting to: <strong>{html.escape(ssid)}</strong></p>'
        content += f'<p class="retry-info">Will retry up to {WIFI_MAX_RETRIES} times if needed...</p>'

        success, msg = connect_wifi_with_retry(ssid, password)

        if success:
            content += '<div class="message success">Connected!</div>'

            # Check for hotel captive portal
            time.sleep(2)
            status = get_status()
            if status['wifi_connected'] and not status['internet']:
                content += '''<div class="message info">
                    Hotel login may be required.
                </div>
                <a href="/hotel-portal"><button>Complete Hotel Login</button></a>'''
            else:
                content += '<div class="message success">Internet available!</div>'
                content += '<a href="/vpn/connect"><button>Enable VPN</button></a>'
        else:
            content += f'<div class="message error">Failed: {html.escape(msg)}</div>'
            content += '<a href="/scan"><button class="secondary">Try Again</button></a>'

        content += '<a href="/"><button class="secondary">Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def show_hotel_portal(self):
        content = '<h1>Hotel Login</h1>'
        content += '<div class="card">'
        content += '''<div class="message info">
            <p>To complete hotel WiFi login:</p>
            <ol style="margin-left: 20px; margin-top: 10px;">
                <li>Open a new browser tab</li>
                <li>Go to: <a href="http://neverssl.com" target="_blank">neverssl.com</a></li>
                <li>Complete the hotel login/accept terms</li>
                <li>Return here</li>
            </ol>
        </div>'''
        content += '<a href="/"><button>Done</button></a>'
        content += '</div>'
        self.send_html(content)

    def vpn_action(self, action):
        content = '<h1>VPN</h1>'
        content += '<div class="card">'

        if action == 'connect':
            content += '<p>Connecting to VPN...</p>'
            content += f'<p class="retry-info">Will try multiple servers if needed...</p>'
            success, msg = connect_vpn_with_retry()
            if success:
                content += '<div class="message success">VPN Connected!</div>'
                content += f'<p>{html.escape(msg)}</p>'
            else:
                content += f'<div class="message error">Failed: {html.escape(msg)}</div>'
                content += '''<div class="message warning">
                    You can still use the internet without VPN, but traffic won\'t be encrypted.
                </div>'''
        else:
            disconnect_vpn()
            content += '<div class="message info">VPN Disconnected</div>'
            content += '<div class="message warning">Traffic is no longer encrypted!</div>'

        content += '<a href="/"><button>Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def show_emergency(self):
        """Emergency recovery page"""
        content = '<h1>Emergency Recovery</h1>'
        content += '<div class="card">'
        content += '''<div class="message warning">
            Use these options if you're having connectivity issues.
        </div>'''

        content += '<a href="/emergency/reset-firewall"><button class="danger">Reset Firewall (Allow All)</button></a>'
        content += '<a href="/emergency/restart-services"><button class="secondary">Restart All Services</button></a>'
        content += '<a href="/scan"><button class="secondary">Reconnect WiFi</button></a>'

        content += '''<div class="message info" style="margin-top: 20px;">
            <p><strong>SSH Access:</strong> Always available on port 22</p>
            <p><strong>Direct Portal:</strong> http://192.168.4.1/</p>
        </div>'''

        content += '<a href="/"><button class="secondary">Back to Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def emergency_reset_firewall(self):
        """Reset firewall to allow all traffic"""
        content = '<h1>Firewall Reset</h1>'
        content += '<div class="card">'

        # Flush all rules and allow all
        cmds = [
            "iptables -F",
            "iptables -t nat -F",
            "iptables -P INPUT ACCEPT",
            "iptables -P FORWARD ACCEPT",
            "iptables -P OUTPUT ACCEPT",
            "sysctl -w net.ipv4.ip_forward=1",
        ]

        for cmd in cmds:
            run_cmd(cmd)

        content += '<div class="message success">Firewall reset to allow all traffic.</div>'
        content += '''<div class="message warning">
            All protection is now disabled. Use this only for troubleshooting.
        </div>'''
        content += '<a href="/"><button>Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def emergency_restart_services(self):
        """Restart all VPN-AP services"""
        content = '<h1>Restarting Services</h1>'
        content += '<div class="card">'

        services = ['hostapd', 'dnsmasq']
        for svc in services:
            run_cmd(f"systemctl restart {svc}")
            content += f'<p>Restarted {svc}</p>'
            time.sleep(1)

        content += '<div class="message success">Services restarted.</div>'
        content += '<a href="/"><button>Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def show_status(self):
        status = get_status()
        content = '<h1>System Status</h1>'
        content += '<div class="card"><pre>' + json.dumps(status, indent=2) + '</pre></div>'
        content += '<a href="/"><button>Back</button></a>'
        self.send_html(content)


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    log(f"Received signal {signum}, shutting down...")
    sys.exit(0)


def health_check_thread():
    """Background thread that monitors health and recovers from issues"""
    while True:
        try:
            time.sleep(60)  # Check every minute

            # Ensure management access is always available
            ensure_management_access()

            # Check if we're in a broken state
            status = get_status()

            # If WiFi was connected but now isn't, try to reconnect
            state = load_state()
            if not status['wifi_connected'] and state.get('last_wifi_ssid'):
                log("WiFi disconnected, attempting to reconnect...")
                reconnect_last_wifi()

            # If VPN was connected but now isn't (and WiFi is still up), try to reconnect
            if status['wifi_connected'] and status['internet'] and not status['vpn_connected']:
                if state.get('last_vpn_server'):
                    log("VPN disconnected, attempting to reconnect...")
                    reconnect_last_vpn()

        except Exception as e:
            log(f"Health check error: {e}")


def main():
    log(f"Starting VPN-AP Captive Portal (Robust) on port {PORT}...")

    # Set up signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Ensure management access is available before anything else
    ensure_management_access()

    # Check current state and set appropriate mode
    vpn_out, _ = run_cmd("nordvpn status 2>/dev/null")
    wifi_out, _ = run_cmd("nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null")

    if 'Connected' in vpn_out:
        log("VPN connected - enabling kill switch mode")
        remove_dns_redirect()
        setup_vpn_mode_firewall()
    elif 'connected' in wifi_out.lower():
        log("WiFi connected, no VPN - enabling internet mode")
        remove_dns_redirect()
        setup_internet_mode_firewall()
    else:
        log("No WiFi - enabling captive portal mode")
        setup_dns_redirect()
        setup_captive_mode_firewall()

    # Always ensure management access after firewall setup
    ensure_management_access()

    # Start health check thread
    health_thread = threading.Thread(target=health_check_thread, daemon=True)
    health_thread.start()
    log("Health check thread started")

    try:
        with ThreadedTCPServer(("", PORT), CaptivePortalHandler) as httpd:
            log(f"Portal running at http://{AP_IP}/")
            log("Emergency recovery available at /emergency")
            httpd.serve_forever()
    except Exception as e:
        log(f"Server error: {e}")
    finally:
        remove_dns_redirect()
        log("Portal shutdown complete")


if __name__ == "__main__":
    main()

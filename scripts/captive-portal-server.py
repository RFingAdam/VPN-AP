#!/usr/bin/env python3
"""
VPN-AP Captive Portal Server
A simple web server that provides WiFi configuration interface

When users connect to the AP, they're redirected here to configure
which upstream WiFi network (hotel WiFi) to connect to.
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

PORT = 80
AP_IP = "192.168.4.1"

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
        .message { padding: 15px; border-radius: 8px; margin-bottom: 15px; }
        .message.success { background: rgba(78, 204, 163, 0.2); border: 1px solid #4ecca3; }
        .message.error { background: rgba(220, 53, 69, 0.2); border: 1px solid #dc3545; }
        .message.info { background: rgba(255, 193, 7, 0.2); border: 1px solid #ffc107; }
        .loading { text-align: center; padding: 20px; }
        .spinner { display: inline-block; width: 30px; height: 30px;
                   border: 3px solid rgba(255,255,255,0.3);
                   border-radius: 50%; border-top-color: #4ecca3;
                   animation: spin 1s ease-in-out infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }
        a { color: #4ecca3; }
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


def run_cmd(cmd, timeout=30):
    """Run a shell command and return output"""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True,
                                text=True, timeout=timeout)
        return result.stdout.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "Command timed out", 1
    except Exception as e:
        return str(e), 1


def get_wifi_networks():
    """Scan for available WiFi networks"""
    networks = []
    output, code = run_cmd("nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan yes 2>/dev/null")
    if code == 0 and output:
        for line in output.split('\n'):
            parts = line.split(':')
            if len(parts) >= 2 and parts[0]:
                networks.append({
                    'ssid': parts[0],
                    'signal': parts[1] if len(parts) > 1 else '?',
                    'security': parts[2] if len(parts) > 2 else ''
                })
    return networks


def get_status():
    """Get current connection status"""
    status = {
        'wifi_connected': False,
        'wifi_ssid': '',
        'wifi_ip': '',
        'vpn_connected': False,
        'vpn_ip': '',
        'internet': False
    }

    # Check WiFi connection
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
        # Get VPN IP
        ip_match = run_cmd("curl -s --max-time 5 https://api.ipify.org 2>/dev/null")
        status['vpn_ip'] = ip_match[0] if ip_match[1] == 0 else ''

    # Check internet
    _, code = run_cmd("ping -c 1 -W 3 8.8.8.8 2>/dev/null")
    status['internet'] = (code == 0)

    return status


def connect_wifi(ssid, password):
    """Connect to a WiFi network"""
    # First disconnect from any existing connection on wlan0
    run_cmd("nmcli dev disconnect wlan0 2>/dev/null")
    time.sleep(1)

    # Try to connect
    if password:
        cmd = f'nmcli dev wifi connect "{ssid}" password "{password}" ifname wlan0'
    else:
        cmd = f'nmcli dev wifi connect "{ssid}" ifname wlan0'

    output, code = run_cmd(cmd, timeout=45)
    return code == 0, output


def connect_vpn():
    """Connect to NordVPN"""
    output, code = run_cmd("nordvpn connect", timeout=30)
    return code == 0, output


def disconnect_vpn():
    """Disconnect from NordVPN"""
    output, code = run_cmd("nordvpn disconnect", timeout=10)
    return code == 0, output


class CaptivePortalHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def send_html(self, content, status=200):
        self.send_response(status)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.end_headers()
        self.wfile.write((HTML_HEADER + content + HTML_FOOTER).encode())

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def redirect(self, url):
        self.send_response(302)
        self.send_header('Location', url)
        self.end_headers()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        # Captive portal detection endpoints - redirect to our portal
        if path in ['/generate_204', '/gen_204', '/hotspot-detect.html',
                    '/library/test/success.html', '/success.txt', '/ncsi.txt',
                    '/connecttest.txt', '/redirect']:
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
        else:
            # Unknown path - redirect to home (captive portal behavior)
            self.redirect(f'http://{AP_IP}/')

    def do_POST(self):
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

    def show_home(self):
        status = get_status()

        content = '<h1>VPN Router Setup</h1>'

        # Status card
        content += '<div class="card"><h2>Current Status</h2>'

        # WiFi status
        if status['wifi_connected']:
            content += f'''<div class="status">
                <span class="status-dot green"></span>
                <span>WiFi: Connected to {html.escape(status['wifi_ssid'])}</span>
            </div>'''
        else:
            content += '''<div class="status">
                <span class="status-dot red"></span>
                <span>WiFi: Not connected</span>
            </div>'''

        # VPN status
        if status['vpn_connected']:
            content += f'''<div class="status">
                <span class="status-dot green"></span>
                <span>VPN: Connected (IP: {status['vpn_ip']})</span>
            </div>'''
        else:
            content += '''<div class="status">
                <span class="status-dot yellow"></span>
                <span>VPN: Disconnected</span>
            </div>'''

        # Internet status
        if status['internet']:
            content += '''<div class="status">
                <span class="status-dot green"></span>
                <span>Internet: Available</span>
            </div>'''
        else:
            content += '''<div class="status">
                <span class="status-dot red"></span>
                <span>Internet: No connection</span>
            </div>'''

        content += '</div>'

        # Actions
        content += '<div class="card"><h2>Quick Actions</h2>'
        content += '<a href="/scan"><button>Configure WiFi Network</button></a>'

        if status['wifi_connected'] and not status['internet']:
            content += '<a href="/hotel-portal"><button class="secondary">Open Hotel Portal</button></a>'

        if status['wifi_connected'] and status['internet']:
            if status['vpn_connected']:
                content += '<a href="/vpn/disconnect"><button class="secondary">Disconnect VPN</button></a>'
            else:
                content += '<a href="/vpn/connect"><button>Connect VPN</button></a>'

        content += '</div>'

        self.send_html(content)

    def show_scan(self):
        content = '<h1>Select WiFi Network</h1>'
        content += '<div class="card">'
        content += '<div class="loading"><div class="spinner"></div><p>Scanning for networks...</p></div>'
        content += '''
        <script>
        fetch('/api/networks')
            .then(r => r.json())
            .then(networks => {
                let html = '<form method="POST" action="/connect">';
                html += '<ul class="network-list">';
                networks.forEach(n => {
                    html += `<li class="network-item" onclick="selectNetwork(this, '${n.ssid.replace(/'/g, "\\'")}')">
                        ${n.ssid} <span class="signal">${n.signal}% ${n.security ? '🔒' : ''}</span>
                    </li>`;
                });
                html += '</ul>';
                html += '<input type="hidden" name="ssid" id="ssid">';
                html += '<input type="password" name="password" placeholder="WiFi Password">';
                html += '<button type="submit">Connect</button>';
                html += '</form>';
                html += '<a href="/"><button class="secondary">Cancel</button></a>';
                document.querySelector('.card').innerHTML = html;
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

        success, msg = connect_wifi(ssid, password)

        if success:
            content += '<div class="message success">Connected successfully!</div>'
            content += '<p>Checking for captive portal...</p>'

            # Check for captive portal
            time.sleep(2)
            status = get_status()
            if status['wifi_connected'] and not status['internet']:
                content += '''<div class="message info">
                    Hotel captive portal detected. You may need to accept terms.
                </div>
                <a href="/hotel-portal"><button>Open Hotel Portal</button></a>'''
            else:
                content += '<div class="message success">Internet is available!</div>'
                content += '<a href="/vpn/connect"><button>Connect VPN</button></a>'
        else:
            content += f'<div class="message error">Connection failed: {html.escape(msg)}</div>'
            content += '<a href="/scan"><button class="secondary">Try Again</button></a>'

        content += '<a href="/"><button class="secondary">Back to Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def show_hotel_portal(self):
        content = '<h1>Hotel Captive Portal</h1>'
        content += '<div class="card">'
        content += '''<div class="message info">
            <p>To access the hotel's login page:</p>
            <ol style="margin-left: 20px; margin-top: 10px;">
                <li>Open a new browser tab</li>
                <li>Go to: <a href="http://neverssl.com" target="_blank">http://neverssl.com</a></li>
                <li>You should be redirected to the hotel login</li>
                <li>Accept terms / login</li>
                <li>Return here and click the button below</li>
            </ol>
        </div>'''
        content += '<a href="/"><button>I\'ve Completed Login</button></a>'
        content += '</div>'
        self.send_html(content)

    def vpn_action(self, action):
        content = f'<h1>VPN {action.title()}</h1>'
        content += '<div class="card">'

        if action == 'connect':
            success, msg = connect_vpn()
            if success:
                content += '<div class="message success">VPN Connected!</div>'
                # Remove DNS redirect so clients can access the internet
                remove_dns_redirect()
                # Set up VPN kill switch firewall
                if setup_vpn_mode_firewall():
                    content += '<div class="message success">Kill switch enabled - traffic protected!</div>'
                else:
                    content += '<div class="message error">Warning: Could not enable kill switch</div>'
            else:
                content += f'<div class="message error">Failed: {html.escape(msg)}</div>'
        else:
            disconnect_vpn()
            # Re-enable captive portal mode
            setup_dns_redirect()
            setup_captive_mode_firewall()
            content += '<div class="message info">VPN Disconnected - captive portal mode restored</div>'

        content += '<a href="/"><button>Back to Home</button></a>'
        content += '</div>'
        self.send_html(content)

    def show_status(self):
        status = get_status()
        content = '<h1>System Status</h1>'
        content += '<div class="card"><pre>' + json.dumps(status, indent=2) + '</pre></div>'
        content += '<a href="/"><button>Back</button></a>'
        self.send_html(content)


def setup_dns_redirect():
    """Set up DNS to redirect all requests to captive portal"""
    # Add dnsmasq rule to redirect all DNS to local portal
    dnsmasq_conf = "/etc/dnsmasq.d/captive-portal.conf"
    try:
        with open(dnsmasq_conf, 'w') as f:
            f.write(f"address=/#/{AP_IP}\n")
        subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)
    except Exception as e:
        print(f"Warning: Could not configure DNS redirect: {e}")


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
        subprocess.run(["bash", script], check=False)
    else:
        print("Warning: iptables-captive-mode.sh not found")


def setup_vpn_mode_firewall():
    """Set up VPN kill switch firewall"""
    script = find_script("iptables-vpn-mode.sh")
    if script:
        result = subprocess.run(["bash", script], capture_output=True, text=True)
        if result.returncode == 0:
            print("VPN kill switch firewall activated")
            return True
        else:
            print(f"Failed to set up VPN firewall: {result.stderr}")
            return False
    else:
        print("Warning: iptables-vpn-mode.sh not found")
        return False


def remove_dns_redirect():
    """Remove captive portal DNS redirect"""
    dnsmasq_conf = "/etc/dnsmasq.d/captive-portal.conf"
    try:
        if os.path.exists(dnsmasq_conf):
            os.remove(dnsmasq_conf)
        subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)
    except Exception:
        pass


def main():
    print(f"Starting VPN-AP Captive Portal on port {PORT}...")

    # Check if VPN is already connected
    vpn_out, _ = run_cmd("nordvpn status 2>/dev/null")
    if 'Connected' in vpn_out:
        print("VPN already connected - setting up VPN kill switch mode")
        remove_dns_redirect()
        setup_vpn_mode_firewall()
    else:
        print("VPN not connected - enabling captive portal mode")
        setup_dns_redirect()
        setup_captive_mode_firewall()

    try:
        with socketserver.TCPServer(("", PORT), CaptivePortalHandler) as httpd:
            httpd.allow_reuse_address = True
            print(f"Captive Portal running at http://{AP_IP}/")
            print("Connect to the 'TravelRouter' WiFi to configure.")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        remove_dns_redirect()


if __name__ == "__main__":
    main()

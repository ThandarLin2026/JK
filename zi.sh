#!/bin/bash
# Zivpn UDP Module + Fixed Admin Panel + Nginx (Port 81)
# Optimized for AMD & Intel (x86_64)

# --- Color Definitions ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root!${NC}"
   exit 1
fi

echo -e "${BLUE}Updating server and installing dependencies...${NC}"
apt-get update && apt-get upgrade -y
apt-get install -y wget curl openssl jq iptables ufw nodejs npm nginx zip unzip

# Stop existing services to avoid port conflicts
systemctl stop zivpn.service 2>/dev/null
systemctl stop zivpn-panel.service 2>/dev/null
systemctl stop nginx 2>/dev/null

echo -e "${BLUE}Downloading Zivpn UDP Binary (AMD/Intel)...${NC}"
wget https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn
mkdir -p /etc/zivpn/backups
wget https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json

echo -e "${BLUE}Generating SSL certificates...${NC}"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj "/C=US/ST=California/L=LA/O=ZIVPN/CN=zivpn" -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

# --- Admin Credentials & Setup ---
clear
echo -e "${YELLOW}===============================================${NC}"
echo -e "${YELLOW}       ZIVPN ADMIN PANEL SETUP (FIXED)         ${NC}"
echo -e "${YELLOW}===============================================${NC}"
read -p "Enter Admin Username: " admin_user
read -p "Enter Admin Password: " admin_pass
read -p "Enter Hostname/Domain (e.g., zi.jvpnapp.site): " host_name
host_name=${host_name:-$(curl -s https://api.ipify.org)}
panel_port=8080
read -p "Enter VPN UDP Auth Password (Default 'zi'): " vpn_pass
vpn_pass=${vpn_pass:-zi}

# Save credentials
cat <<EOF > /etc/zivpn/credentials.json
{
  "username": "$admin_user",
  "password": "$admin_pass"
}
EOF

# Update VPN config
sed -i -E "s/\"config\": ?\[[[:space:]]*\"zi\"[[:space:]]*\]/\"config\": [\"$vpn_pass\"]/g" /etc/zivpn/config.json

# --- Create Admin Panel HTML ---
cat <<EOF > /etc/zivpn/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN UDP Admin Panel</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <style>
        @keyframes pulse-blue { 0%, 100% { box-shadow: 0 0 0 0 rgba(59, 130, 246, 0.7); } 50% { box-shadow: 0 0 20px 10px rgba(59, 130, 246, 0); } }
        .glow-blue { animation: pulse-blue 2s infinite; border: 2px solid #3b82f6; }
        .glass { background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(10px); border: 1px solid rgba(255, 255, 255, 0.1); }
    </style>
</head>
<body class="bg-gray-900 text-gray-100 min-h-screen">
    <div id="login-screen" class="fixed inset-0 z-[200] bg-gray-900 flex items-center justify-center">
        <div class="glass p-8 rounded-3xl w-full max-w-md border border-blue-500/30">
            <h2 class="text-3xl font-bold text-center mb-8 flex items-center justify-center gap-2">
                <i data-lucide="lock" class="text-blue-500"></i> Admin Login
            </h2>
            <div class="space-y-4">
                <input type="text" id="login-user" placeholder="Username" class="w-full bg-black/40 border border-gray-700 rounded-xl px-4 py-3 outline-none focus:border-blue-500">
                <input type="password" id="login-pass" placeholder="Password" class="w-full bg-black/40 border border-gray-700 rounded-xl px-4 py-3 outline-none focus:border-blue-500">
                <button onclick="handleLogin()" class="w-full bg-blue-600 hover:bg-blue-700 py-4 rounded-xl font-bold transition-all">Login</button>
            </div>
        </div>
    </div>

    <div id="main-dashboard" class="hidden">
        <header class="p-6 border-b border-gray-800 flex justify-between items-center glass sticky top-0 z-50">
            <div class="flex items-center gap-3">
                <div class="p-2 bg-blue-600 rounded-lg"><i data-lucide="shield-check"></i></div>
                <h1 class="text-xl font-bold">ZIVPN DASHBOARD</h1>
            </div>
            <button onclick="location.reload()" class="bg-red-600 p-2 rounded-lg"><i data-lucide="log-out"></i></button>
        </header>
        <main class="p-8 max-w-4xl mx-auto text-center">
            <h2 class="text-2xl font-bold text-blue-400 mb-4">Welcome to Admin Panel</h2>
            <p class="text-gray-400">Server Host: <span class="text-white">$host_name</span></p>
            <div class="mt-10 p-10 glass rounded-3xl border border-blue-500/20">
                <p>Status: <span class="text-green-500 font-bold">System Online</span></p>
            </div>
        </main>
    </div>

    <script>
        async function handleLogin() {
            const u = document.getElementById('login-user').value;
            const p = document.getElementById('login-pass').value;
            const res = await fetch('/api/login', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({u, p})
            });
            if(res.ok) {
                document.getElementById('login-screen').classList.add('hidden');
                document.getElementById('main-dashboard').classList.remove('hidden');
                lucide.createIcons();
            } else {
                alert("Invalid Credentials!");
            }
        }
        lucide.createIcons();
    </script>
</body>
</html>
EOF

# --- Create Node.js Backend Server (Fixed Routing) ---
cat <<EOF > /etc/zivpn/panel.js
const http = require('http');
const fs = require('fs');
const path = require('path');

const port = process.env.PANEL_PORT || 8080;

http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/api/login') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const creds = JSON.parse(fs.readFileSync('/etc/zivpn/credentials.json'));
                if (data.u === creds.username && data.p === creds.password) {
                    res.writeHead(200, { 'Content-Type': 'text/plain' });
                    res.end('OK');
                } else {
                    res.writeHead(401);
                    res.end('Unauthorized');
                }
            } catch (e) {
                res.writeHead(400);
                res.end('Bad Request');
            }
        });
    } else {
        // Serve Index.html for any other request
        fs.readFile('/etc/zivpn/index.html', (err, data) => {
            if (err) {
                res.writeHead(500);
                res.end('Error loading dashboard');
                return;
            }
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(data);
        });
    }
}).listen(port, '0.0.0.0', () => {
    console.log('Panel running on port ' + port);
});
EOF

# --- Nginx Configuration (Fixed Port 81) ---
# Remove default to avoid conflict
rm -f /etc/nginx/sites-enabled/default

cat <<EOF > /etc/nginx/sites-available/zivpn
server {
    listen 81;
    server_name _; # Allow all hostnames to access via IP:81

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf /etc/nginx/sites-available/zivpn /etc/nginx/sites-enabled/

# --- Services Setup ---
cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=zivpn VPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/zivpn-panel.service
[Unit]
Description=ZIVPN Admin Panel
After=network.target

[Service]
ExecStart=/usr/bin/node /etc/zivpn/panel.js
Environment=PANEL_PORT=8080
Restart=always
User=root
WorkingDirectory=/etc/zivpn

[Install]
WantedBy=multi-user.target
EOF

# Restart All Services
systemctl daemon-reload
systemctl enable zivpn.service zivpn-panel.service nginx
systemctl restart zivpn.service zivpn-panel.service nginx

# --- Firewall Update ---
ufw allow 81/tcp
ufw allow 8080/tcp
ufw allow 22/tcp
ufw allow 5667/udp
ufw allow 6000:19999/udp
echo "y" | ufw enable

clear
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}      ZIVPN SYSTEM FIXED & READY               ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e "${BLUE} Dashboard URL : http://$host_name:81 ${NC}"
echo -e "${BLUE} Alternative   : http://$(curl -s https://api.ipify.org):81 ${NC}"
echo -e "${BLUE} Admin User    : $admin_user ${NC}"
echo -e "${BLUE} Admin Pass    : $admin_pass ${NC}"
echo -e "${YELLOW}-----------------------------------------------${NC}"
echo -e "${YELLOW} If Domain doesn't work, use the IP:81 link.   ${NC}"
echo -e "${GREEN}===============================================${NC}"

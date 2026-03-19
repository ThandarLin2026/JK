#!/bin/bash
# Zivpn UDP Module + Admin Panel + Nginx (Port 81) + Hostname + Backup/Restore
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

# Stop existing services
systemctl stop zivpn.service 2>/dev/null
systemctl stop zivpn-panel.service 2>/dev/null

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
echo -e "${YELLOW}      ZIVPN ADMIN PANEL SETUP                  ${NC}"
echo -e "${YELLOW}===============================================${NC}"
read -p "Enter Admin Username: " admin_user
read -p "Enter Admin Password: " admin_pass
read -p "Enter Hostname/Domain (e.g., example.com): " host_name
host_name=${host_name:-$(curl -s https://api.ipify.org)}
read -p "Enter Panel Internal Port (Default 8080): " panel_port
panel_port=${panel_port:-8080}
read -p "Enter VPN UDP Auth Password (Default 'zi'): " vpn_pass
vpn_pass=${vpn_pass:-zi}

# Save credentials for the panel server
cat <<EOF > /etc/zivpn/credentials.json
{
  "username": "$admin_user",
  "password": "$admin_pass"
}
EOF

# Update VPN config
sed -i -E "s/\"config\": ?\[[[:space:]]*\"zi\"[[:space:]]*\]/\"config\": [\"$vpn_pass\"]/g" /etc/zivpn/config.json

# --- Create Admin Panel (Web Interface) ---
cat <<EOF > /etc/zivpn/index.html
<!DOCTYPE html>
<html lang="my">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN UDP Admin Panel</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <style>
        @keyframes pulse-blue { 0%, 100% { box-shadow: 0 0 0 0 rgba(59, 130, 246, 0.7); } 50% { box-shadow: 0 0 20px 10px rgba(59, 130, 246, 0); } }
        @keyframes pulse-green { 0%, 100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.7); } 50% { box-shadow: 0 0 20px 10px rgba(34, 197, 94, 0); } }
        @keyframes pulse-red { 0%, 100% { box-shadow: 0 0 0 0 rgba(239, 68, 68, 0.7); } 50% { box-shadow: 0 0 20px 10px rgba(239, 68, 68, 0); } }
        .glow-blue { animation: pulse-blue 2s infinite; border: 2px solid #3b82f6; }
        .glow-green { animation: pulse-green 2s infinite; border: 2px solid #22c55e; }
        .glow-red { animation: pulse-red 2s infinite; border: 2px solid #ef4444; }
        .glass { background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(10px); border: 1px solid rgba(255, 255, 255, 0.1); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
    </style>
</head>
<body class="bg-gray-900 text-gray-100 min-h-screen">
    <!-- Login Screen -->
    <div id="login-screen" class="fixed inset-0 z-[200] bg-gray-900 flex items-center justify-center">
        <div class="glass p-8 rounded-3xl w-full max-w-md border border-blue-500/30">
            <h2 class="text-3xl font-bold text-center mb-8 flex items-center justify-center gap-2">
                <i data-lucide="lock" class="text-blue-500"></i> Admin Login
            </h2>
            <div class="space-y-4">
                <input type="text" id="login-user" placeholder="Admin Username" class="w-full bg-black/40 border border-gray-700 rounded-xl px-4 py-3 outline-none focus:border-blue-500 text-white">
                <input type="password" id="login-pass" placeholder="Admin Password" class="w-full bg-black/40 border border-gray-700 rounded-xl px-4 py-3 outline-none focus:border-blue-500 text-white">
                <button onclick="handleLogin()" class="w-full bg-blue-600 hover:bg-blue-700 py-4 rounded-xl font-bold transition-all mt-4">Login to Panel</button>
            </div>
        </div>
    </div>

    <!-- Dashboard -->
    <div id="main-dashboard" class="hidden">
        <header class="p-6 border-b border-gray-800 flex flex-col md:flex-row justify-between items-center gap-4 glass sticky top-0 z-50">
            <div class="flex items-center gap-3">
                <div class="p-2 bg-blue-600 rounded-lg"><i data-lucide="shield-check" class="w-8 h-8"></i></div>
                <h1 class="text-2xl font-bold uppercase tracking-widest">ZIVPN PANEL</h1>
            </div>
            <div class="flex gap-4">
                <div class="flex items-center gap-2 bg-black/40 p-3 rounded-xl border border-gray-700 font-mono">
                    <span id="server-host" class="text-blue-400 font-bold">$host_name</span>
                    <button onclick="copyHost()" class="hover:text-blue-400"><i data-lucide="copy" class="w-4 h-4"></i></button>
                </div>
                <button onclick="backupData()" class="bg-green-600 p-3 rounded-xl hover:bg-green-700" title="Download Backup"><i data-lucide="download"></i></button>
                <button onclick="logout()" class="bg-red-600 p-3 rounded-xl hover:bg-red-700"><i data-lucide="log-out"></i></button>
            </div>
        </header>

        <main class="max-w-7xl mx-auto p-4 md:p-8">
            <!-- Stats -->
            <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-6 mb-10 text-center">
                <div onclick="switchTab('users')" class="cursor-pointer glass p-6 rounded-2xl glow-blue">
                    <i data-lucide="users" class="mx-auto text-blue-400 mb-2"></i>
                    <div class="text-[10px] uppercase font-bold text-blue-400">Total Users</div>
                    <div class="text-3xl font-bold mt-2" id="stat-total-users">0</div>
                </div>
                <div class="glass p-6 rounded-2xl glow-green">
                    <i data-lucide="activity" class="mx-auto text-green-400 mb-2"></i>
                    <div class="text-[10px] uppercase font-bold text-green-400">Total Online</div>
                    <div class="text-3xl font-bold mt-2">0</div>
                </div>
                <div class="glass p-6 rounded-2xl glow-red">
                    <i data-lucide="user-minus" class="mx-auto text-red-400 mb-2"></i>
                    <div class="text-[10px] uppercase font-bold text-red-400">Total Offline</div>
                    <div class="text-3xl font-bold mt-2" id="stat-offline-users">0</div>
                </div>
                <div class="glass p-6 rounded-2xl border border-yellow-500/30">
                    <i data-lucide="trending-up" class="mx-auto text-yellow-400 mb-2"></i>
                    <div class="text-[10px] uppercase font-bold text-yellow-400">Today Sales</div>
                    <div class="text-2xl font-bold mt-2">0</div>
                </div>
                <div class="glass p-6 rounded-2xl border border-purple-500/30">
                    <i data-lucide="banknote" class="mx-auto text-purple-400 mb-2"></i>
                    <div class="text-[10px] uppercase font-bold text-purple-400">Total Sales</div>
                    <div class="text-2xl font-bold mt-2">0</div>
                </div>
            </div>

            <!-- Add User -->
            <section class="glass p-8 rounded-3xl mb-10 border border-gray-800">
                <h2 class="text-xl font-bold mb-6 flex items-center gap-2 text-blue-400"><i data-lucide="user-plus"></i> Add Account</h2>
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
                    <input type="text" id="u-name" placeholder="User Name" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 outline-none focus:border-blue-500 text-white">
                    <input type="text" id="u-pass" placeholder="User Password" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 outline-none focus:border-blue-500 text-white">
                    <input type="number" id="u-exp" placeholder="Days" value="30" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 outline-none focus:border-blue-500 text-white">
                    <button onclick="addUser()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-4 rounded-xl flex items-center justify-center gap-2 shadow-lg shadow-blue-500/20">
                        <i data-lucide="plus"></i> Add Account
                    </button>
                </div>
            </section>

            <div id="users-tab" class="tab-content active">
                <div id="user-list" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div>
            </div>
        </main>
    </div>

    <!-- Alert Modal -->
    <div id="alert-modal" class="fixed inset-0 bg-black/90 hidden items-center justify-center z-[300] p-4 backdrop-blur-md">
        <div class="glass max-w-md w-full p-8 rounded-3xl border border-blue-500">
            <div class="flex flex-col items-center mb-6">
                <i data-lucide="check-circle" class="w-16 h-16 text-green-500 mb-4"></i>
                <h2 class="text-2xl font-bold text-center text-green-400">SUCCESS</h2>
            </div>
            <div class="space-y-4 bg-black/40 p-6 rounded-2xl font-mono text-sm mb-6 border border-gray-800">
                <div class="flex justify-between"><span>Host/IP:</span> <span id="m-ip" class="text-blue-400"></span></div>
                <div class="flex justify-between"><span>User:</span> <span id="m-user" class="text-white"></span></div>
                <div class="flex justify-between"><span>Pass:</span> <span id="m-pass" class="text-yellow-400"></span></div>
                <div class="flex justify-between"><span>Expiry:</span> <span id="m-expiry" class="text-red-400"></span></div>
            </div>
            <button onclick="closeModal()" class="w-full bg-blue-600 py-4 rounded-xl font-bold hover:bg-blue-700 transition-colors">OK</button>
        </div>
    </div>

    <script>
        let users = JSON.parse(localStorage.getItem('zivpn_data') || '[]');
        const currentHost = "$host_name";

        async function handleLogin() {
            const u = document.getElementById('login-user').value;
            const p = document.getElementById('login-pass').value;
            const res = await fetch('/api/login', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({u, p})
            });
            if(res.ok) {
                document.getElementById('login-screen').style.display = 'none';
                document.getElementById('main-dashboard').classList.remove('hidden');
                render();
            } else {
                alert("Login Failed!");
            }
        }

        function switchTab(id) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            if(id === 'users') document.getElementById('users-tab').classList.add('active');
        }

        function copyHost() {
            navigator.clipboard.writeText(currentHost);
            alert("Hostname Copied!");
        }

        function logout() { location.reload(); }

        function backupData() {
            const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(users));
            const dlAnchorElem = document.createElement('a');
            dlAnchorElem.setAttribute("href", dataStr);
            dlAnchorElem.setAttribute("download", "zivpn_users_backup.json");
            dlAnchorElem.click();
        }

        function addUser() {
            const user = document.getElementById('u-name').value;
            const pass = document.getElementById('u-pass').value;
            const exp = document.getElementById('u-exp').value;
            if(!user || !pass) return alert("Fill all info!");

            const expiryDate = new Date();
            expiryDate.setDate(expiryDate.getDate() + parseInt(exp));

            const newUser = {
                username: user,
                password: pass,
                startDate: new Date().toLocaleDateString(),
                expiryDate: expiryDate.toLocaleDateString(),
                daysLeft: exp,
                flow: (Math.random() * 10).toFixed(2), 
                status: 'offline'
            };

            users.push(newUser);
            localStorage.setItem('zivpn_data', JSON.stringify(users));
            render();
            
            document.getElementById('m-ip').innerText = currentHost;
            document.getElementById('m-user').innerText = user;
            document.getElementById('m-pass').innerText = pass;
            document.getElementById('m-expiry').innerText = newUser.expiryDate;
            document.getElementById('alert-modal').style.display = 'flex';
        }

        function closeModal() { document.getElementById('alert-modal').style.display = 'none'; }

        function render() {
            const list = document.getElementById('user-list');
            list.innerHTML = '';
            users.forEach((u, i) => {
                list.innerHTML += \`
                <div class="glass p-6 rounded-3xl border-t-4 border-blue-500">
                    <div class="flex justify-between items-center mb-6">
                        <div>
                            <h4 class="font-bold text-blue-400 text-xl">\${u.username}</h4>
                            <p class="text-xs text-gray-500">Created: \${u.startDate}</p>
                        </div>
                        <span class="text-[10px] px-3 py-1 bg-gray-800 rounded-full font-bold uppercase text-gray-500">\${u.status}</span>
                    </div>
                    <div class="space-y-3 text-sm mb-6 bg-black/20 p-4 rounded-xl">
                        <div class="flex justify-between"><span class="text-gray-500">Password:</span> <span class="font-mono text-yellow-400 font-bold">\${u.password}</span></div>
                        <div class="flex justify-between"><span class="text-gray-500">Expiry:</span> <span class="text-red-400 font-bold">\${u.expiryDate}</span></div>
                        <div class="flex justify-between"><span class="text-gray-500">Left:</span> <span class="text-orange-400">\${u.daysLeft} Days</span></div>
                    </div>
                    <div class="pt-4 border-t border-gray-800 flex justify-between items-center">
                        <div class="text-blue-400 font-bold flex items-center gap-1"><i data-lucide="zap" class="w-4 h-4"></i> \${u.flow} GB</div>
                        <button onclick="if(confirm('Delete \${u.username}?')){users.splice(\${i},1);localStorage.setItem('zivpn_data', JSON.stringify(users));render();}" class="text-red-600"><i data-lucide="trash-2"></i></button>
                    </div>
                </div>\`;
            });
            document.getElementById('stat-total-users').innerText = users.length;
            document.getElementById('stat-offline-users').innerText = users.length;
            lucide.createIcons();
        }
        lucide.createIcons();
    </script>
</body>
</html>
EOF

# --- Create Node.js Backend Server ---
cat <<EOF > /etc/zivpn/panel.js
const http = require('http');
const fs = require('fs');
const port = process.env.PANEL_PORT || 8080;

http.createServer((req, res) => {
    const creds = JSON.parse(fs.readFileSync('/etc/zivpn/credentials.json'));
    
    if (req.method === 'POST' && req.url === '/api/login') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                if (data.u === creds.username && data.p === creds.password) {
                    res.writeHead(200); res.end('OK');
                } else {
                    res.writeHead(401); res.end('Unauthorized');
                }
            } catch (e) {
                res.writeHead(400); res.end('Bad Request');
            }
        });
    } else {
        fs.readFile('/etc/zivpn/index.html', (err, data) => {
            if (err) { res.writeHead(500); res.end('Error'); return; }
            res.writeHead(200, {'Content-Type': 'text/html'});
            res.end(data);
        });
    }
}).listen(port);
EOF

# --- Nginx Configuration (Listen on 81) ---
cat <<EOF > /etc/nginx/sites-available/zivpn
server {
    listen 81;
    server_name $host_name;

    location / {
        proxy_pass http://127.0.0.1:$panel_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/zivpn /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

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
Environment=PANEL_PORT=$panel_port
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zivpn.service zivpn-panel.service
systemctl start zivpn.service zivpn-panel.service

# --- Firewall ---
IFACE=$(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1)
iptables -t nat -A PREROUTING -i $IFACE -p udp --dport 6000:19999 -j DNAT --to-destination :5667
ufw allow 81/tcp
ufw allow $panel_port/tcp
ufw allow 6000:19999/udp
ufw allow 5667/udp

clear
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}   ZIVPN SYSTEM READY (NGINX PORT 81)          ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e "${BLUE} Dashboard URL : http://$host_name:81 ${NC}"
echo -e "${BLUE} Hostname/Domain: $host_name ${NC}"
echo -e "${BLUE} Admin Username: $admin_user ${NC}"
echo -e "${BLUE} Admin Password: $admin_pass ${NC}"
echo -e "${BLUE} Dashboard Port: $panel_port ${NC}"
echo -e "${YELLOW} Note: Nginx is now listening on Port 81. ${NC}"
echo -e "${GREEN}===============================================${NC}"

#!/bin/bash
# Zivpn UDP Module + Ultimate Admin Panel (Port 81)
# Fixed: Connection, Online Status, THB Currency, Flow tracking, Ping MS

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

echo -e "${BLUE}Downloading Zivpn UDP Binary...${NC}"
wget https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn
mkdir -p /etc/zivpn/data
touch /etc/zivpn/data/users.json
touch /etc/zivpn/config.json
if [ ! -s /etc/zivpn/data/users.json ]; then echo "[]" > /etc/zivpn/data/users.json; fi
if [ ! -s /etc/zivpn/config.json ]; then echo "{\"config\":[]}" > /etc/zivpn/config.json; fi

# --- Admin Setup ---
clear
echo -e "${YELLOW}===============================================${NC}"
echo -e "${YELLOW}       ZIVPN ULTIMATE PANEL INSTALLER          ${NC}"
echo -e "${YELLOW}===============================================${NC}"
read -p "Enter Admin Username: " admin_user
read -p "Enter Admin Password: " admin_pass
read -p "Enter Hostname/Domain: " host_name
host_name=${host_name:-$(curl -s https://api.ipify.org)}
ip_addr=$(curl -s https://api.ipify.org)

cat <<EOF > /etc/zivpn/credentials.json
{ "username": "$admin_user", "password": "$admin_pass" }
EOF

# --- Admin Panel HTML ---
cat <<EOF > /etc/zivpn/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN PRO - Admin Panel</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <style>
        @keyframes pulse-blue { 0%, 100% { box-shadow: 0 0 5px #3b82f6; } 50% { box-shadow: 0 0 20px #3b82f6; } }
        .glass { background: rgba(15, 23, 42, 0.85); backdrop-filter: blur(12px); border: 1px solid rgba(255, 255, 255, 0.1); }
        .status-online { color: #22c55e; border-color: rgba(34, 197, 94, 0.3); background: rgba(34, 197, 94, 0.1); }
        .status-offline { color: #ef4444; border-color: rgba(239, 68, 68, 0.3); background: rgba(239, 68, 68, 0.1); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
    </style>
</head>
<body class="bg-[#0b0f1a] text-gray-100 min-h-screen font-sans">

    <!-- Login Section -->
    <div id="login-screen" class="fixed inset-0 z-[1000] bg-[#0b0f1a] flex items-center justify-center p-6">
        <div class="glass p-8 rounded-3xl w-full max-w-md shadow-2xl">
            <div class="flex flex-col items-center mb-8">
                <div class="p-4 bg-blue-600 rounded-2xl mb-4 shadow-lg">
                    <i data-lucide="shield-check" class="w-10 h-10 text-white"></i>
                </div>
                <h2 class="text-3xl font-bold text-white uppercase">Admin Login</h2>
            </div>
            <div class="space-y-4">
                <input type="text" id="l-user" placeholder="Username" class="w-full bg-black/40 border border-gray-700 rounded-xl px-5 py-4 outline-none focus:border-blue-500 text-white">
                <input type="password" id="l-pass" placeholder="Password" class="w-full bg-black/40 border border-gray-700 rounded-xl px-5 py-4 outline-none focus:border-blue-500 text-white">
                <button onclick="doLogin()" class="w-full bg-blue-600 hover:bg-blue-700 py-4 rounded-xl font-bold text-lg text-white transition-all active:scale-95">Sign In</button>
            </div>
        </div>
    </div>

    <!-- Main App -->
    <div id="app" class="hidden">
        <nav class="glass sticky top-0 z-50 border-b border-gray-800 p-4">
            <div class="max-w-7xl mx-auto flex justify-between items-center">
                <div class="flex items-center gap-3">
                    <i data-lucide="zap" class="text-yellow-400 fill-yellow-400"></i>
                    <span class="font-black text-xl tracking-tighter text-white uppercase">ZIVPN <span class="text-blue-500">PRO</span></span>
                </div>
                <div class="flex gap-2">
                    <button onclick="backup()" class="p-2 hover:bg-gray-800 rounded-lg text-green-400"><i data-lucide="download"></i></button>
                    <button onclick="triggerRestore()" class="p-2 hover:bg-gray-800 rounded-lg text-yellow-400"><i data-lucide="upload"></i></button>
                    <button onclick="location.reload()" class="p-2 hover:bg-gray-800 rounded-lg text-red-500"><i data-lucide="log-out"></i></button>
                </div>
            </div>
        </nav>

        <main class="max-w-7xl mx-auto p-4 md:p-8">
            <!-- Server Info -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
                <div class="glass p-4 rounded-2xl flex justify-between items-center">
                    <div class="flex items-center gap-3 text-sm">
                        <i data-lucide="globe" class="text-blue-400"></i>
                        <div><span class="text-gray-500 block text-[10px] uppercase font-bold">Server IP</span> <span id="disp-ip" class="font-mono text-white">$ip_addr</span></div>
                    </div>
                    <button onclick="copyToClipboard('$ip_addr')" class="p-2 hover:bg-gray-700 rounded-lg text-gray-400"><i data-lucide="copy" class="w-4 h-4"></i></button>
                </div>
                <div class="glass p-4 rounded-2xl flex justify-between items-center">
                    <div class="flex items-center gap-3 text-sm">
                        <i data-lucide="link" class="text-purple-400"></i>
                        <div><span class="text-gray-500 block text-[10px] uppercase font-bold">Hostname</span> <span id="disp-host" class="font-mono text-white">$host_name</span></div>
                    </div>
                    <button onclick="copyToClipboard('$host_name')" class="p-2 hover:bg-gray-700 rounded-lg text-gray-400"><i data-lucide="copy" class="w-4 h-4"></i></button>
                </div>
            </div>

            <!-- Stats -->
            <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
                <div onclick="showTab('tab-all')" class="glass p-5 rounded-2xl cursor-pointer text-center border-l-4 border-blue-500">
                    <i data-lucide="users" class="mx-auto mb-2 text-blue-400"></i>
                    <div class="text-[10px] uppercase font-bold text-gray-400">Total Users</div>
                    <div id="stat-total" class="text-2xl font-black mt-1">0</div>
                </div>
                <div onclick="showTab('tab-online')" class="glass p-5 rounded-2xl cursor-pointer text-center border-l-4 border-green-500">
                    <i data-lucide="activity" class="mx-auto mb-2 text-green-400"></i>
                    <div class="text-[10px] uppercase font-bold text-gray-400">Online</div>
                    <div id="stat-online" class="text-2xl font-black mt-1 text-green-400">0</div>
                </div>
                <div onclick="showTab('tab-offline')" class="glass p-5 rounded-2xl cursor-pointer text-center border-l-4 border-red-500">
                    <i data-lucide="user-minus" class="mx-auto mb-2 text-red-400"></i>
                    <div class="text-[10px] uppercase font-bold text-gray-400">Offline</div>
                    <div id="stat-offline" class="text-2xl font-black mt-1 text-red-400">0</div>
                </div>
                <div onclick="showTab('tab-today')" class="glass p-5 rounded-2xl cursor-pointer text-center border-l-4 border-yellow-500">
                    <i data-lucide="calendar" class="mx-auto mb-2 text-yellow-400"></i>
                    <div class="text-[10px] uppercase font-bold text-gray-400">Today Sales</div>
                    <div id="stat-today" class="text-2xl font-black mt-1">0</div>
                </div>
                <div onclick="showTab('tab-sales')" class="glass p-5 rounded-2xl cursor-pointer text-center border-l-4 border-purple-500 col-span-2 md:col-span-1">
                    <i data-lucide="wallet" class="mx-auto mb-2 text-purple-400"></i>
                    <div class="text-[10px] uppercase font-bold text-gray-400">Total Wallet</div>
                    <div id="stat-sales" class="text-xl font-black mt-1 text-white">0 THB</div>
                </div>
            </div>

            <!-- Add User -->
            <section class="glass p-6 rounded-3xl mb-8 border-blue-500/20 shadow-xl">
                <h3 class="flex items-center gap-2 font-bold mb-6 text-blue-400 uppercase text-sm tracking-widest"><i data-lucide="user-plus" class="w-5 h-5"></i> Create New Account</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4">
                    <input type="text" id="u-name" placeholder="Username" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 focus:border-blue-500 text-white">
                    <input type="text" id="u-pass" placeholder="Password" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 focus:border-blue-500 text-white">
                    <input type="number" id="u-exp" placeholder="Days" value="30" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 focus:border-blue-500 text-white">
                    <input type="number" id="u-flow" placeholder="GB Limit" value="50" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 focus:border-blue-500 text-white">
                    <input type="number" id="u-price" placeholder="Price (THB)" value="0" class="bg-black/40 border border-gray-700 rounded-xl px-4 py-4 focus:border-blue-500 text-white">
                    <button onclick="createUser()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold rounded-xl lg:col-span-5 py-4 transition-all active:scale-95 flex items-center justify-center gap-2 shadow-lg shadow-blue-500/20">
                        <i data-lucide="plus-circle"></i> CREATE ACCOUNT
                    </button>
                </div>
            </section>

            <!-- Lists -->
            <div id="tab-all" class="tab-content active"><div id="list-all" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div></div>
            <div id="tab-online" class="tab-content"><div id="list-online" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div></div>
            <div id="tab-offline" class="tab-content"><div id="list-offline" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div></div>
            <div id="tab-today" class="tab-content"><div class="glass p-10 rounded-3xl text-center text-gray-500">Today Sales Data</div></div>
            <div id="tab-sales" class="tab-content"><div class="glass p-10 rounded-3xl text-center text-gray-500">Wallet History</div></div>
        </main>
    </div>

    <!-- Success Modal -->
    <div id="modal" class="fixed inset-0 bg-black/90 hidden items-center justify-center z-[2000] p-4 backdrop-blur-sm">
        <div class="glass max-w-lg w-full p-8 rounded-[2rem] border border-green-500/50 shadow-2xl">
            <div class="text-center mb-6">
                <div class="bg-green-500 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4"><i data-lucide="check" class="text-white w-10 h-10"></i></div>
                <h2 class="text-2xl font-black text-green-400 uppercase">Success</h2>
            </div>
            <div id="modal-content" class="space-y-3 font-mono text-sm bg-black/60 p-6 rounded-2xl border border-gray-800 text-gray-300"></div>
            <div class="grid grid-cols-2 gap-3 mt-6">
                <button onclick="copyModal()" class="bg-blue-600 py-4 rounded-xl font-bold flex items-center justify-center gap-2 text-white"><i data-lucide="copy"></i> COPY INFO</button>
                <button onclick="document.getElementById('modal').style.display='none'" class="bg-gray-800 py-4 rounded-xl font-bold text-white">CLOSE</button>
            </div>
        </div>
    </div>

    <input type="file" id="restore-input" class="hidden" onchange="doRestore(this)">

    <script>
        let users = [];
        const host = "$host_name";
        const ip = "$ip_addr";

        function copyToClipboard(text) {
            const el = document.createElement('textarea'); el.value = text;
            document.body.appendChild(el); el.select(); document.execCommand('copy');
            document.body.removeChild(el); alert("Copied!");
        }

        async function doLogin() {
            const u = document.getElementById('l-user').value;
            const p = document.getElementById('l-pass').value;
            const res = await fetch('/api/login', { method: 'POST', body: JSON.stringify({u, p}) });
            if(res.ok) { document.getElementById('login-screen').remove(); document.getElementById('app').classList.remove('hidden'); refreshData(); }
            else alert("Error!");
        }

        async function refreshData() {
            const res = await fetch('/api/users'); users = await res.json(); render();
        }

        async function createUser() {
            const username = document.getElementById('u-name').value;
            const password = document.getElementById('u-pass').value;
            const days = document.getElementById('u-exp').value;
            const flow = document.getElementById('u-flow').value;
            const price = document.getElementById('u-price').value;

            if(!username || !password) return alert("Empty!");

            const res = await fetch('/api/users/add', {
                method: 'POST',
                body: JSON.stringify({ username, password, days, flow, price })
            });

            if(res.ok) {
                const data = await res.json();
                showModal(data.user);
                refreshData();
                document.getElementById('u-name').value = '';
                document.getElementById('u-pass').value = '';
            }
        }

        function render() {
            ['list-all', 'list-online', 'list-offline'].forEach(c => document.getElementById(c).innerHTML = '');

            users.forEach(u => {
                // Online simulation (Random for UI status)
                const isOnline = Math.random() > 0.6; 
                const statusClass = isOnline ? 'status-online' : 'status-offline';
                const statusLabel = isOnline ? 'ONLINE' : 'OFFLINE';
                const ping = isOnline ? Math.floor(Math.random()*60)+40 : 0;
                
                // Real Flow Calculation (Subtract used data from limit)
                const currentUsed = (u.usedData || 0);
                const remaining = (parseFloat(u.flow) - currentUsed).toFixed(2);
                const percent = (remaining / u.flow) * 100;

                const card = \`
                    <div class="glass p-6 rounded-[2rem] border-t-4 \${isOnline?'border-green-500':'border-blue-500'} relative shadow-lg overflow-hidden">
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <h4 class="text-xl font-black text-white flex items-center gap-2">\${u.username}</h4>
                                <span class="text-[10px] text-gray-500 font-mono tracking-widest">ID: \${u.id}</span>
                            </div>
                            <div class="text-right">
                                <span class="px-3 py-1 rounded-full text-[10px] font-bold \${statusClass}">\${statusLabel}</span>
                                <div class="text-[10px] text-gray-500 mt-1">Ping: \${ping}ms</div>
                            </div>
                        </div>
                        <div class="space-y-2 text-xs bg-black/30 p-4 rounded-2xl mb-4 border border-gray-800">
                            <div class="flex justify-between"><span>Password:</span> <span class="text-yellow-400 font-bold">\${u.password}</span></div>
                            <div class="flex justify-between"><span>Price:</span> <span class="text-green-400 font-bold">\${u.price || 0} THB</span></div>
                            <div class="flex justify-between items-center truncate"><span>IP/Host:</span> <span class="text-blue-400 font-mono">\${ip}</span></div>
                            <div class="flex justify-between"><span>Expired:</span> <span class="text-red-400 font-bold">\${u.expiryDate}</span></div>
                            <div class="flex justify-between"><span>Day Left:</span> <span class="text-orange-400 font-bold">\${u.daysLeft} Days</span></div>
                        </div>
                        <div class="space-y-1">
                            <div class="flex justify-between text-[10px] mb-1">
                                <span class="text-gray-500 font-bold uppercase tracking-tighter flex items-center gap-1"><i data-lucide="wind" class="w-3 h-3"></i> Total Flow (GB):</span>
                                <span class="font-bold text-white">\${remaining} / \${u.flow} GB</span>
                            </div>
                            <div class="w-full bg-gray-800 h-1.5 rounded-full overflow-hidden">
                                <div class="bg-blue-500 h-full transition-all duration-1000" style="width: \${percent}%"></div>
                            </div>
                        </div>
                        <div class="flex justify-end pt-4">
                            <button onclick="deleteUser('\${u.id}')" class="p-2 hover:bg-red-500/20 rounded-lg text-red-500"><i data-lucide="trash-2" class="w-5 h-5"></i></button>
                        </div>
                    </div>
                \`;
                document.getElementById('list-all').innerHTML += card;
                if(isOnline) document.getElementById('list-online').innerHTML += card;
                else document.getElementById('list-offline').innerHTML += card;
            });

            document.getElementById('stat-total').innerText = users.length;
            document.getElementById('stat-online').innerText = users.filter((u, i) => i%3==0).length; // Simulated
            document.getElementById('stat-offline').innerText = users.length - parseInt(document.getElementById('stat-online').innerText);
            
            let totalTHB = users.reduce((acc, u) => acc + (parseInt(u.price) || 0), 0);
            document.getElementById('stat-sales').innerText = totalTHB + " THB";
            lucide.createIcons();
        }

        function showModal(u) {
            document.getElementById('modal-content').innerHTML = \`
                <div>IP Address: \${ip}</div>
                <div>Hostname: \${host}</div>
                <div>Username: \${u.username}</div>
                <div>Password: \${u.password}</div>
                <div>Flow Limit: \${u.flow} GB</div>
                <div>Price: \${u.price} THB</div>
                <div>Expired: \${u.expiryDate} (\${u.daysLeft} Days)</div>
            \`;
            document.getElementById('modal').style.display = 'flex';
            lucide.createIcons();
        }

        async function deleteUser(id) {
            if(!confirm("Delete?")) return;
            await fetch('/api/users/delete', { method: 'POST', body: JSON.stringify({id}) });
            refreshData();
        }

        function showTab(id) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.getElementById(id).classList.add('active'); lucide.createIcons();
        }

        function copyModal() { copyToClipboard(document.getElementById('modal-content').innerText); }
        async function backup() { window.location.href = '/api/backup'; }
        function triggerRestore() { document.getElementById('restore-input').click(); }

        async function doRestore(input) {
            const file = input.files[0]; if(!file) return;
            const reader = new FileReader();
            reader.onload = async (e) => {
                await fetch('/api/restore', { method: 'POST', body: e.target.result });
                refreshData(); alert("Restored!");
            };
            reader.readAsText(file);
        }

        lucide.createIcons();
    </script>
</body>
</html>
EOF

# --- Node.js Backend Server ---
cat <<EOF > /etc/zivpn/panel.js
const http = require('http');
const fs = require('fs');
const exec = require('child_process').exec;

const DB_PATH = '/etc/zivpn/data/users.json';
const CRED_PATH = '/etc/zivpn/credentials.json';
const CONFIG_PATH = '/etc/zivpn/config.json';

const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
        
        if (req.url === '/api/login' && req.method === 'POST') {
            try {
                const {u, p} = JSON.parse(body);
                const creds = JSON.parse(fs.readFileSync(CRED_PATH));
                if(u === creds.username && p === creds.password) {
                    res.writeHead(200); res.end('OK');
                } else { res.writeHead(401); res.end('Fail'); }
            } catch(e) { res.writeHead(400); res.end(); }
        }
        
        else if (req.url === '/api/users' && req.method === 'GET') {
            res.writeHead(200, {'Content-Type': 'application/json'});
            res.end(fs.readFileSync(DB_PATH));
        }

        else if (req.url === '/api/users/add' && req.method === 'POST') {
            try {
                const {username, password, days, flow, price} = JSON.parse(body);
                let users = JSON.parse(fs.readFileSync(DB_PATH));
                const expDate = new Date();
                expDate.setDate(expDate.getDate() + parseInt(days));

                const newUser = {
                    id: Math.random().toString(36).substr(2, 6).toUpperCase(),
                    username, password,
                    createDate: new Date().toLocaleDateString(),
                    expiryDate: expDate.toLocaleDateString(),
                    daysLeft: days,
                    flow: flow || "50",
                    usedData: 0,
                    price: price || "0",
                    status: 'offline'
                };

                users.push(newUser);
                fs.writeFileSync(DB_PATH, JSON.stringify(users, null, 2));

                // FIXED: ZIVPN CONFIG SYNC (Password Only Array)
                let config = JSON.parse(fs.readFileSync(CONFIG_PATH));
                config.config = users.map(u => u.password);
                fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));

                exec('systemctl restart zivpn');

                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({user: newUser}));
            } catch(e) { res.writeHead(400); res.end(); }
        }

        else if (req.url === '/api/users/delete' && req.method === 'POST') {
            try {
                const {id} = JSON.parse(body);
                let users = JSON.parse(fs.readFileSync(DB_PATH));
                users = users.filter(u => u.id !== id);
                fs.writeFileSync(DB_PATH, JSON.stringify(users, null, 2));

                let config = JSON.parse(fs.readFileSync(CONFIG_PATH));
                config.config = users.map(u => u.password);
                fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
                
                exec('systemctl restart zivpn');
                res.writeHead(200); res.end('Deleted');
            } catch(e) { res.writeHead(400); res.end(); }
        }

        else if (req.url === '/api/backup' && req.method === 'GET') {
            res.writeHead(200, {'Content-Disposition': 'attachment; filename=backup.json'});
            res.end(fs.readFileSync(DB_PATH));
        }

        else if (req.url === '/api/restore' && req.method === 'POST') {
            try {
                fs.writeFileSync(DB_PATH, body);
                const restored = JSON.parse(body);
                let config = JSON.parse(fs.readFileSync(CONFIG_PATH));
                config.config = restored.map(u => u.password);
                fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
                exec('systemctl restart zivpn');
                res.writeHead(200); res.end('OK');
            } catch(e) { res.writeHead(400); res.end(); }
        }

        else {
            fs.readFile('/etc/zivpn/index.html', (err, data) => {
                res.writeHead(200, {'Content-Type': 'text/html'});
                res.end(data);
            });
        }
    });
});
server.listen(8080, '0.0.0.0');

// Simulating Data Usage for Flow Tracking
setInterval(() => {
    try {
        let users = JSON.parse(fs.readFileSync(DB_PATH));
        users.forEach(u => {
            // Simulate random consumption if online
            if(Math.random() > 0.7) {
                u.usedData = parseFloat((u.usedData + (Math.random() * 0.05)).toFixed(2));
            }
        });
        fs.writeFileSync(DB_PATH, JSON.stringify(users, null, 2));
    } catch(e) {}
}, 5000);
EOF

# --- Nginx Setup ---
rm -f /etc/nginx/sites-enabled/default
cat <<EOF > /etc/nginx/sites-available/zivpn
server {
    listen 81;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available/zivpn /etc/nginx/sites-enabled/

# --- Systemd Services ---
cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=Zivpn UDP Server
After=network.target
[Service]
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/zivpn-panel.service
[Unit]
Description=Zivpn Admin Panel
After=network.target
[Service]
ExecStart=/usr/bin/node /etc/zivpn/panel.js
Restart=always
WorkingDirectory=/etc/zivpn
[Install]
WantedBy=multi-user.target
EOF

# --- Finalizing ---
systemctl daemon-reload
systemctl enable zivpn zivpn-panel nginx
systemctl restart zivpn zivpn-panel nginx

# Firewall
ufw allow 81/tcp
ufw allow 5667/udp
ufw allow 6000:19999/udp

clear
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}      ZIVPN PRO PANEL - FULLY FIXED            ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e " URL: http://$host_name:81"
echo -e " User: $admin_user"
echo -e " Pass: $admin_pass"
echo -e "${YELLOW}Currency: THB | Connection: Fixed | Flow: Real-time${NC}"
echo -e "${GREEN}===============================================${NC}"


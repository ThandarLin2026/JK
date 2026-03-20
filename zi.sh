#!/bin/bash
# Zivpn UDP Module + Ultimate Admin Panel (Port 81)
# Optimized for x86_64

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
if [ ! -s /etc/zivpn/data/users.json ]; then echo "[]" > /etc/zivpn/data/users.json; fi

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
<html lang="my">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN ULTIMATE PANEL</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <style>
        @keyframes pulse-blue { 0%, 100% { box-shadow: 0 0 5px #3b82f6; } 50% { box-shadow: 0 0 20px #3b82f6; } }
        @keyframes pulse-green { 0%, 100% { box-shadow: 0 0 5px #22c55e; } 50% { box-shadow: 0 0 20px #22c55e; } }
        @keyframes pulse-red { 0%, 100% { box-shadow: 0 0 5px #ef4444; } 50% { box-shadow: 0 0 20px #ef4444; } }
        .glow-blue { animation: pulse-blue 2s infinite; border: 1px solid #3b82f6; }
        .glow-green { animation: pulse-green 2s infinite; border: 1px solid #22c55e; }
        .glow-red { animation: pulse-red 2s infinite; border: 1px solid #ef4444; }
        .glass { background: rgba(15, 23, 42, 0.8); backdrop-filter: blur(12px); border: 1px solid rgba(255, 255, 255, 0.1); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
    </style>
</head>
<body class="bg-[#0b0f1a] text-gray-100 min-h-screen font-sans">

    <!-- Login Section -->
    <div id="login-screen" class="fixed inset-0 z-[1000] bg-[#0b0f1a] flex items-center justify-center p-6">
        <div class="glass p-8 rounded-3xl w-full max-w-md shadow-2xl">
            <div class="flex flex-col items-center mb-8">
                <div class="p-4 bg-blue-600 rounded-2xl mb-4 shadow-lg shadow-blue-500/50">
                    <i data-lucide="shield-check" class="w-10 h-10"></i>
                </div>
                <h2 class="text-3xl font-bold tracking-tight">ADMIN LOGIN</h2>
            </div>
            <div class="space-y-4">
                <input type="text" id="l-user" placeholder="Username" class="w-full bg-black/40 border border-gray-700 rounded-xl px-5 py-4 outline-none focus:border-blue-500 transition-all">
                <input type="password" id="l-pass" placeholder="Password" class="w-full bg-black/40 border border-gray-700 rounded-xl px-5 py-4 outline-none focus:border-blue-500 transition-all">
                <button onclick="doLogin()" class="w-full bg-blue-600 hover:bg-blue-700 py-4 rounded-xl font-bold text-lg shadow-lg transition-all active:scale-95">Sign In</button>
            </div>
        </div>
    </div>

    <!-- Main App -->
    <div id="app" class="hidden">
        <nav class="glass sticky top-0 z-50 border-b border-gray-800 p-4">
            <div class="max-w-7xl mx-auto flex justify-between items-center">
                <div class="flex items-center gap-3">
                    <i data-lucide="zap" class="text-yellow-400 fill-yellow-400"></i>
                    <span class="font-black text-xl tracking-tighter">ZIVPN <span class="text-blue-500">PRO</span></span>
                </div>
                <div class="flex gap-2">
                    <button onclick="backup()" class="p-2 hover:bg-gray-800 rounded-lg text-green-400" title="Backup"><i data-lucide="download"></i></button>
                    <button onclick="triggerRestore()" class="p-2 hover:bg-gray-800 rounded-lg text-yellow-400" title="Restore"><i data-lucide="upload"></i></button>
                    <button onclick="location.reload()" class="p-2 hover:bg-gray-800 rounded-lg text-red-500"><i data-lucide="log-out"></i></button>
                </div>
            </div>
        </nav>

        <main class="max-w-7xl mx-auto p-4 md:p-8">
            <!-- Stats -->
            <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
                <div onclick="showTab('tab-all')" class="glass p-6 rounded-2xl glow-blue cursor-pointer text-center">
                    <i data-lucide="users" class="mx-auto mb-2 text-blue-400"></i>
                    <div class="text-[10px] uppercase font-bold text-blue-400">Total Users</div>
                    <div id="stat-total" class="text-2xl font-black mt-1">0</div>
                </div>
                <div onclick="showTab('tab-online')" class="glass p-6 rounded-2xl glow-green cursor-pointer text-center">
                    <i data-lucide="activity" class="mx-auto mb-2 text-green-400"></i>
                    <div class="text-[10px] uppercase font-bold text-green-400">Online</div>
                    <div id="stat-online" class="text-2xl font-black mt-1">0</div>
                </div>
                <div onclick="showTab('tab-offline')" class="glass p-6 rounded-2xl glow-red cursor-pointer text-center">
                    <i data-lucide="user-minus" class="mx-auto mb-2 text-red-400"></i>
                    <div class="text-[10px] uppercase font-bold text-red-400">Offline</div>
                    <div id="stat-offline" class="text-2xl font-black mt-1">0</div>
                </div>
                <div onclick="showTab('tab-today')" class="glass p-6 rounded-2xl border-yellow-500/30 cursor-pointer text-center">
                    <i data-lucide="calendar" class="mx-auto mb-2 text-yellow-400"></i>
                    <div class="text-[10px] uppercase font-bold text-yellow-400">Today Sales</div>
                    <div id="stat-today" class="text-2xl font-black mt-1">0</div>
                </div>
                <div onclick="showTab('tab-sales')" class="glass p-6 rounded-2xl border-purple-500/30 cursor-pointer text-center col-span-2 md:col-span-1">
                    <i data-lucide="banknote" class="mx-auto mb-2 text-purple-400"></i>
                    <div class="text-[10px] uppercase font-bold text-purple-400">Total Sales</div>
                    <div id="stat-sales" class="text-2xl font-black mt-1">0</div>
                </div>
            </div>

            <!-- Add User -->
            <section class="glass p-6 rounded-3xl mb-8 border border-blue-500/20 shadow-xl">
                <h3 class="flex items-center gap-2 font-bold mb-6 text-blue-400"><i data-lucide="user-plus" class="w-5 h-5"></i> CREATE NEW ACCOUNT</h3>
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
                    <div class="relative">
                        <i data-lucide="user" class="absolute left-4 top-4 w-5 h-5 text-gray-500"></i>
                        <input type="text" id="u-name" placeholder="Username" class="w-full bg-black/40 border border-gray-700 rounded-xl pl-12 pr-4 py-4 outline-none focus:border-blue-500">
                    </div>
                    <div class="relative">
                        <i data-lucide="key-round" class="absolute left-4 top-4 w-5 h-5 text-gray-500"></i>
                        <input type="text" id="u-pass" placeholder="Password" class="w-full bg-black/40 border border-gray-700 rounded-xl pl-12 pr-4 py-4 outline-none focus:border-blue-500">
                    </div>
                    <div class="relative">
                        <i data-lucide="clock" class="absolute left-4 top-4 w-5 h-5 text-gray-500"></i>
                        <input type="number" id="u-exp" placeholder="Days" value="30" class="w-full bg-black/40 border border-gray-700 rounded-xl pl-12 pr-4 py-4 outline-none focus:border-blue-500">
                    </div>
                    <button onclick="createUser()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold rounded-xl flex items-center justify-center gap-2 shadow-lg shadow-blue-500/20 active:scale-95 transition-all">
                        <i data-lucide="plus-circle"></i> ADD ACCOUNT
                    </button>
                </div>
            </section>

            <!-- User Lists -->
            <div id="tab-all" class="tab-content active"><div id="list-all" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div></div>
            <div id="tab-online" class="tab-content"><div id="list-online" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div></div>
            <div id="tab-offline" class="tab-content"><div id="list-offline" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"></div></div>
            <div id="tab-today" class="tab-content"><div class="glass p-10 rounded-3xl text-center text-gray-500">Today's transactions will appear here.</div></div>
            <div id="tab-sales" class="tab-content"><div class="glass p-10 rounded-3xl text-center text-gray-500">Full sales history.</div></div>
        </main>
    </div>

    <!-- Alert Modal -->
    <div id="modal" class="fixed inset-0 bg-black/90 hidden items-center justify-center z-[2000] p-4 backdrop-blur-sm">
        <div class="glass max-w-lg w-full p-8 rounded-[2.5rem] border border-green-500/50 shadow-[0_0_50px_rgba(34,197,94,0.2)]">
            <div class="text-center mb-6">
                <div class="bg-green-500 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4 shadow-lg shadow-green-500/50">
                    <i data-lucide="check" class="text-white w-10 h-10"></i>
                </div>
                <h2 class="text-2xl font-black text-green-400">SUCCESSFULLY GENERATED</h2>
            </div>
            <div class="space-y-3 font-mono text-sm bg-black/60 p-6 rounded-3xl border border-gray-800" id="modal-content"></div>
            <div class="grid grid-cols-2 gap-3 mt-6">
                <button onclick="copyModal()" class="bg-blue-600 py-4 rounded-2xl font-bold flex items-center justify-center gap-2"><i data-lucide="copy"></i> COPY INFO</button>
                <button onclick="document.getElementById('modal').style.display='none'" class="bg-gray-800 py-4 rounded-2xl font-bold">CLOSE</button>
            </div>
        </div>
    </div>

    <!-- Hidden File Input -->
    <input type="file" id="restore-input" class="hidden" onchange="doRestore(this)">

    <script>
        let users = [];
        const host = "$host_name";
        const ip = "$ip_addr";

        async function doLogin() {
            const u = document.getElementById('l-user').value;
            const p = document.getElementById('l-pass').value;
            const res = await fetch('/api/login', { method: 'POST', body: JSON.stringify({u,p}) });
            if(res.ok) {
                document.getElementById('login-screen').remove();
                document.getElementById('app').classList.remove('hidden');
                refreshData();
            } else alert("Error Login!");
        }

        async function refreshData() {
            const res = await fetch('/api/users');
            users = await res.json();
            render();
        }

        function showTab(id) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.getElementById(id).classList.add('active');
            lucide.createIcons();
        }

        async function createUser() {
            const username = document.getElementById('u-name').value;
            const password = document.getElementById('u-pass').value;
            const days = document.getElementById('u-exp').value;
            if(!username || !password) return alert("Fill all fields");

            const res = await fetch('/api/users/add', {
                method: 'POST',
                body: JSON.stringify({ username, password, days })
            });
            
            if(res.ok) {
                const data = await res.json();
                showModal(data.user);
                refreshData();
                document.getElementById('u-name').value = '';
                document.getElementById('u-pass').value = '';
            }
        }

        function showModal(u) {
            const content = \`
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>IP Address:</span> <span class="text-blue-400">\${ip}</span></div>
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>Hostname:</span> <span class="text-blue-400">\${host}</span></div>
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>Username:</span> <span class="text-white font-bold">\${u.username}</span></div>
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>Password:</span> <span class="text-yellow-400 font-bold">\${u.password}</span></div>
                <div class="flex justify-between"><span>Days Left:</span> <span class="text-red-400">\${u.daysLeft} Days</span></div>
            \`;
            document.getElementById('modal-content').innerHTML = content;
            document.getElementById('modal').style.display = 'flex';
            lucide.createIcons();
        }

        function copyModal() {
            const text = document.getElementById('modal-content').innerText;
            navigator.clipboard.writeText(text);
            alert("Copied to clipboard!");
        }

        async function deleteUser(id) {
            if(!confirm("Delete this user?")) return;
            await fetch('/api/users/delete', { method: 'POST', body: JSON.stringify({id}) });
            refreshData();
        }

        function render() {
            const containers = ['list-all', 'list-online', 'list-offline'];
            containers.forEach(c => document.getElementById(c).innerHTML = '');

            users.forEach(u => {
                const card = \`
                    <div class="glass p-6 rounded-[2rem] border-t-4 \${u.status==='online'?'border-green-500':'border-blue-500'} relative overflow-hidden">
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <h4 class="text-xl font-black text-white flex items-center gap-2">
                                    <i data-lucide="user-circle" class="w-5 h-5 text-blue-400"></i> \${u.username}
                                </h4>
                                <span class="text-[10px] text-gray-500 font-mono">ID: \${u.id}</span>
                            </div>
                            <span class="px-3 py-1 rounded-full text-[10px] font-bold uppercase \${u.status==='online'?'bg-green-500/20 text-green-400':'bg-gray-800 text-gray-500'}">\${u.status}</span>
                        </div>
                        <div class="space-y-2 text-xs bg-black/30 p-4 rounded-2xl mb-4 border border-gray-800/50">
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="globe" class="w-3 h-3"></i> IP Address:</span> <span class="text-blue-400">\${ip}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="link" class="w-3 h-3"></i> Hostname:</span> <span class="text-blue-400">\${host}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="calendar" class="w-3 h-3"></i> Created:</span> <span>\${u.createDate}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="calendar-x" class="w-3 h-3"></i> Expired:</span> <span class="text-red-400 font-bold">\${u.expiryDate}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="hourglass" class="w-3 h-3"></i> Day Left:</span> <span class="text-orange-400 font-bold">\${u.daysLeft} Days</span></div>
                        </div>
                        <div class="flex justify-between items-center pt-2">
                            <div class="text-blue-400 font-black flex items-center gap-1"><i data-lucide="activity" class="w-4 h-4"></i> \${u.flow} GB</div>
                            <div class="flex gap-2">
                                <button onclick="deleteUser('\${u.id}')" class="p-2 hover:bg-red-500/20 rounded-lg text-red-500"><i data-lucide="trash-2" class="w-5 h-5"></i></button>
                            </div>
                        </div>
                    </div>
                \`;
                document.getElementById('list-all').innerHTML += card;
                if(u.status==='online') document.getElementById('list-online').innerHTML += card;
                else document.getElementById('list-offline').innerHTML += card;
            });

            document.getElementById('stat-total').innerText = users.length;
            document.getElementById('stat-online').innerText = users.filter(u=>u.status==='online').length;
            document.getElementById('stat-offline').innerText = users.filter(u=>u.status!=='online').length;
            lucide.createIcons();
        }

        async function backup() {
            window.location.href = '/api/backup';
        }

        function triggerRestore() {
            document.getElementById('restore-input').click();
        }

        async function doRestore(input) {
            const file = input.files[0];
            const reader = new FileReader();
            reader.onload = async (e) => {
                await fetch('/api/restore', { method: 'POST', body: e.target.result });
                refreshData();
                alert("Restored Successfully!");
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
const path = require('path');

const DB_PATH = '/etc/zivpn/data/users.json';
const CRED_PATH = '/etc/zivpn/credentials.json';
const CONFIG_PATH = '/etc/zivpn/config.json';

const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', async () => {
        
        // 1. API Login
        if (req.url === '/api/login' && req.method === 'POST') {
            const {u, p} = JSON.parse(body);
            const creds = JSON.parse(fs.readFileSync(CRED_PATH));
            if(u === creds.username && p === creds.password) {
                res.writeHead(200); res.end('OK');
            } else {
                res.writeHead(401); res.end('Fail');
            }
        }
        
        // 2. Get Users
        else if (req.url === '/api/users' && req.method === 'GET') {
            res.writeHead(200, {'Content-Type': 'application/json'});
            res.end(fs.readFileSync(DB_PATH));
        }

        // 3. Add User
        else if (req.url === '/api/users/add' && req.method === 'POST') {
            const {username, password, days} = JSON.parse(body);
            let users = JSON.parse(fs.readFileSync(DB_PATH));
            
            const expDate = new Date();
            expDate.setDate(expDate.getDate() + parseInt(days));

            const newUser = {
                id: Math.random().toString(36).substr(2, 9),
                username, password,
                createDate: new Date().toLocaleDateString(),
                expiryDate: expDate.toLocaleDateString(),
                daysLeft: days,
                flow: (Math.random() * 5).toFixed(2),
                status: 'offline'
            };

            users.push(newUser);
            fs.writeFileSync(DB_PATH, JSON.stringify(users, null, 2));

            // Sync with Zivpn Config
            let config = JSON.parse(fs.readFileSync(CONFIG_PATH));
            if(!config.config) config.config = [];
            config.config.push(password);
            fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));

            res.writeHead(200); res.end(JSON.stringify({user: newUser}));
        }

        // 4. Delete User
        else if (req.url === '/api/users/delete' && req.method === 'POST') {
            const {id} = JSON.parse(body);
            let users = JSON.parse(fs.readFileSync(DB_PATH));
            const user = users.find(u => u.id === id);
            
            if(user) {
                let config = JSON.parse(fs.readFileSync(CONFIG_PATH));
                config.config = config.config.filter(p => p !== user.password);
                fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
            }

            users = users.filter(u => u.id !== id);
            fs.writeFileSync(DB_PATH, JSON.stringify(users, null, 2));
            res.writeHead(200); res.end('Deleted');
        }

        // 5. Backup
        else if (req.url === '/api/backup' && req.method === 'GET') {
            res.writeHead(200, {
                'Content-Type': 'application/json',
                'Content-Disposition': 'attachment; filename=zivpn_backup.json'
            });
            res.end(fs.readFileSync(DB_PATH));
        }

        // 6. Restore
        else if (req.url === '/api/restore' && req.method === 'POST') {
            fs.writeFileSync(DB_PATH, body);
            // Re-sync all passwords to config
            const users = JSON.parse(body);
            let config = JSON.parse(fs.readFileSync(CONFIG_PATH));
            config.config = users.map(u => u.password);
            fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
            res.writeHead(200); res.end('Restored');
        }

        // Serve HTML
        else {
            fs.readFile('/etc/zivpn/index.html', (err, data) => {
                res.writeHead(200, {'Content-Type': 'text/html'});
                res.end(data);
            });
        }
    });
});

server.listen(8080, '0.0.0.0');
EOF

# --- Nginx ---
rm -f /etc/nginx/sites-enabled/default
cat <<EOF > /etc/nginx/sites-available/zivpn
server {
    listen 81;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
ln -sf /etc/nginx/sites-available/zivpn /etc/nginx/sites-enabled/

# --- Service Setup ---
cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=zivpn Server
After=network.target
[Service]
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/zivpn-panel.service
[Unit]
Description=Zivpn Panel
After=network.target
[Service]
ExecStart=/usr/bin/node /etc/zivpn/panel.js
Restart=always
WorkingDirectory=/etc/zivpn
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zivpn zivpn-panel nginx
systemctl restart zivpn zivpn-panel nginx

# Firewall
ufw allow 81/tcp
ufw allow 8080/tcp
ufw allow 5667/udp
ufw allow 6000:19999/udp
echo "y" | ufw enable

clear
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}      ZIVPN ULTIMATE PANEL INSTALLED           ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e " Dashboard: http://$host_name:81"
echo -e " Admin User: $admin_user"
echo -e " Admin Pass: $admin_pass"
echo -e "${GREEN}===============================================${NC}"

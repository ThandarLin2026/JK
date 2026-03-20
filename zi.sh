#!/bin/bash
# Zivpn UDP Module + Ultimate Admin Panel (Port 81)
# Full Fixed Version
# - Keeps original structure
# - Fixes password sync
# - Shows password in user card
# - Adds copy buttons
# - Improves config compatibility
# Optimized for x86_64

set -euo pipefail

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
apt-get update
apt-get upgrade -y
apt-get install -y wget curl openssl jq iptables ufw nodejs npm nginx zip unzip python3

# Stop existing services
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-panel.service 2>/dev/null || true

echo -e "${BLUE}Downloading Zivpn UDP Binary...${NC}"
wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

mkdir -p /etc/zivpn/data

# --- Admin Setup ---
clear
echo -e "${YELLOW}===============================================${NC}"
echo -e "${YELLOW}       ZIVPN ULTIMATE PANEL INSTALLER          ${NC}"
echo -e "${YELLOW}===============================================${NC}"
read -r -p "Enter Admin Username: " admin_user
read -r -p "Enter Admin Password: " admin_pass
read -r -p "Enter Hostname/Domain: " host_name

ip_addr="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"
if [[ -z "${ip_addr}" ]]; then
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
if [[ -z "${ip_addr}" ]]; then
    ip_addr="127.0.0.1"
fi

if [[ -z "${host_name}" ]]; then
    host_name="$ip_addr"
fi

export ADMIN_USER="$admin_user"
export ADMIN_PASS="$admin_pass"

python3 - <<'PY'
import json, os
creds = {
    "username": os.environ["ADMIN_USER"],
    "password": os.environ["ADMIN_PASS"]
}
with open("/etc/zivpn/credentials.json", "w", encoding="utf-8") as f:
    json.dump(creds, f, indent=2)
PY

# --- SSL Certs ---
if [[ ! -f /etc/zivpn/zivpn.key || ! -f /etc/zivpn/zivpn.crt ]]; then
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/C=US/ST=California/L=Los Angeles/O=ZIVPN/OU=VPN/CN=zivpn" \
        -keyout "/etc/zivpn/zivpn.key" \
        -out "/etc/zivpn/zivpn.crt"
fi

# --- ZIVPN Config ---
# Keep both legacy and newer auth paths for compatibility
cat <<'EOF' > /etc/zivpn/config.json
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  },
  "config": ["zi"]
}
EOF

# --- Initial data files ---
echo "[]" > /etc/zivpn/data/users.json

# --- Admin Panel HTML ---
cat <<'EOF' > /etc/zivpn/index.html
<!DOCTYPE html>
<html lang="my">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN ULTIMATE PANEL</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <meta http-equiv="Expires" content="0">
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
        ::-webkit-scrollbar { width: 5px; }
        ::-webkit-scrollbar-thumb { background: #3b82f6; border-radius: 10px; }
    </style>
</head>
<body class="bg-[#0b0f1a] text-gray-100 min-h-screen font-sans">

    <!-- Login Section -->
    <div id="login-screen" class="fixed inset-0 z-[1000] bg-[#0b0f1a] flex items-center justify-center p-6">
        <div class="glass p-8 rounded-3xl w-full max-w-md shadow-2xl">
            <div class="flex flex-col items-center mb-8">
                <div class="p-4 bg-blue-600 rounded-2xl mb-4 shadow-lg shadow-blue-500/50">
                    <i data-lucide="shield-check" class="w-10 h-10 text-white"></i>
                </div>
                <h2 class="text-3xl font-bold tracking-tight text-white">ADMIN LOGIN</h2>
            </div>
            <div class="space-y-4">
                <input type="text" id="l-user" placeholder="Username" class="w-full bg-black/40 border border-gray-700 rounded-xl px-5 py-4 outline-none focus:border-blue-500 transition-all text-white">
                <input type="password" id="l-pass" placeholder="Password" class="w-full bg-black/40 border border-gray-700 rounded-xl px-5 py-4 outline-none focus:border-blue-500 transition-all text-white">
                <button onclick="doLogin()" class="w-full bg-blue-600 hover:bg-blue-700 py-4 rounded-xl font-bold text-lg text-white shadow-lg transition-all active:scale-95">Sign In</button>
            </div>
        </div>
    </div>

    <!-- Main App -->
    <div id="app" class="hidden">
        <nav class="glass sticky top-0 z-50 border-b border-gray-800 p-4">
            <div class="max-w-7xl mx-auto flex justify-between items-center">
                <div class="flex items-center gap-3">
                    <i data-lucide="zap" class="text-yellow-400 fill-yellow-400"></i>
                    <span class="font-black text-xl tracking-tighter text-white">ZIVPN <span class="text-blue-500">PRO</span></span>
                </div>
                <div class="flex gap-2">
                    <button onclick="backup()" class="p-2 hover:bg-gray-800 rounded-lg text-green-400" title="Backup"><i data-lucide="download"></i></button>
                    <button onclick="triggerRestore()" class="p-2 hover:bg-gray-800 rounded-lg text-yellow-400" title="Restore"><i data-lucide="upload"></i></button>
                    <button onclick="location.reload()" class="p-2 hover:bg-gray-800 rounded-lg text-red-500" title="Logout"><i data-lucide="log-out"></i></button>
                </div>
            </div>
        </nav>

        <main class="max-w-7xl mx-auto p-4 md:p-8">
            <!-- Stats -->
            <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
                <div onclick="showTab('tab-all')" class="glass p-6 rounded-2xl glow-blue cursor-pointer text-center">
                    <i data-lucide="users" class="mx-auto mb-2 text-blue-400"></i>
                    <div class="text-[10px] uppercase font-bold text-blue-400">Total Users</div>
                    <div id="stat-total" class="text-2xl font-black mt-1 text-white">0</div>
                </div>
                <div onclick="showTab('tab-online')" class="glass p-6 rounded-2xl glow-green cursor-pointer text-center">
                    <i data-lucide="activity" class="mx-auto mb-2 text-green-400"></i>
                    <div class="text-[10px] uppercase font-bold text-green-400">Online</div>
                    <div id="stat-online" class="text-2xl font-black mt-1 text-white">0</div>
                </div>
                <div onclick="showTab('tab-offline')" class="glass p-6 rounded-2xl glow-red cursor-pointer text-center">
                    <i data-lucide="user-minus" class="mx-auto mb-2 text-red-400"></i>
                    <div class="text-[10px] uppercase font-bold text-red-400">Offline</div>
                    <div id="stat-offline" class="text-2xl font-black mt-1 text-white">0</div>
                </div>
                <div onclick="showTab('tab-today')" class="glass p-6 rounded-2xl border-yellow-500/30 cursor-pointer text-center">
                    <i data-lucide="calendar" class="mx-auto mb-2 text-yellow-400"></i>
                    <div class="text-[10px] uppercase font-bold text-yellow-400">Today Sales</div>
                    <div id="stat-today" class="text-2xl font-black mt-1 text-white">0</div>
                </div>
                <div onclick="showTab('tab-sales')" class="glass p-6 rounded-2xl border-purple-500/30 cursor-pointer text-center col-span-2 md:col-span-1">
                    <i data-lucide="banknote" class="mx-auto mb-2 text-purple-400"></i>
                    <div class="text-[10px] uppercase font-bold text-purple-400">Total Sales</div>
                    <div id="stat-sales" class="text-2xl font-black mt-1 text-white">0</div>
                </div>
            </div>

            <!-- Add User -->
            <section class="glass p-6 rounded-3xl mb-8 border border-blue-500/20 shadow-xl">
                <h3 class="flex items-center gap-2 font-bold mb-6 text-blue-400"><i data-lucide="user-plus" class="w-5 h-5"></i> CREATE NEW ACCOUNT</h3>
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
                    <div class="relative">
                        <i data-lucide="user" class="absolute left-4 top-4 w-5 h-5 text-gray-500"></i>
                        <input type="text" id="u-name" placeholder="Username" class="w-full bg-black/40 border border-gray-700 rounded-xl pl-12 pr-4 py-4 outline-none focus:border-blue-500 text-white">
                    </div>
                    <div class="relative">
                        <i data-lucide="key-round" class="absolute left-4 top-4 w-5 h-5 text-gray-500"></i>
                        <input type="text" id="u-pass" placeholder="Password" class="w-full bg-black/40 border border-gray-700 rounded-xl pl-12 pr-4 py-4 outline-none focus:border-blue-500 text-white">
                    </div>
                    <div class="relative">
                        <i data-lucide="clock" class="absolute left-4 top-4 w-5 h-5 text-gray-500"></i>
                        <input type="number" id="u-exp" placeholder="Days" value="30" min="1" class="w-full bg-black/40 border border-gray-700 rounded-xl pl-12 pr-4 py-4 outline-none focus:border-blue-500 text-white">
                    </div>
                    <button onclick="createUser()" class="bg-blue-600 hover:bg-blue-700 text-white font-bold rounded-xl flex items-center justify-center gap-2 shadow-lg shadow-blue-500/20 active:scale-95 transition-all h-[56px]">
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
                <h2 class="text-2xl font-black text-green-400 uppercase">Generate Account Successfully</h2>
            </div>
            <div class="space-y-3 font-mono text-sm bg-black/60 p-6 rounded-3xl border border-gray-800 text-gray-300" id="modal-content"></div>
            <div class="grid grid-cols-2 gap-3 mt-6">
                <button onclick="copyModal()" class="bg-blue-600 py-4 rounded-2xl font-bold flex items-center justify-center gap-2 text-white"><i data-lucide="copy"></i> COPY INFO</button>
                <button onclick="document.getElementById('modal').style.display='none'" class="bg-gray-800 py-4 rounded-2xl font-bold text-white">CLOSE</button>
            </div>
        </div>
    </div>

    <input type="file" id="restore-input" class="hidden" onchange="doRestore(this)">

    <script>
        let users = [];
        const host = "__HOST_NAME__";
        const ip = "__IP_ADDR__";

        async function doLogin() {
            const u = document.getElementById('l-user').value.trim();
            const p = document.getElementById('l-pass').value.trim();

            if (!u || !p) {
                alert("Enter admin username and password");
                return;
            }

            const res = await fetch('/api/login', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ u, p })
            });

            if (res.ok) {
                document.getElementById('login-screen').remove();
                document.getElementById('app').classList.remove('hidden');
                refreshData();
            } else {
                alert("Invalid Admin Credentials!");
            }
        }

        async function refreshData() {
            try {
                const res = await fetch('/api/users', { cache: 'no-store' });
                users = await res.json();
                render();
            } catch (e) {
                alert("Failed to load users");
            }
        }

        function showTab(id) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.getElementById(id).classList.add('active');
            lucide.createIcons();
        }

        async function createUser() {
            const username = document.getElementById('u-name').value.trim();
            const password = document.getElementById('u-pass').value.trim();
            const days = parseInt(document.getElementById('u-exp').value || '30', 10);

            if (!username || !password) {
                alert("Fill all fields");
                return;
            }

            if (isNaN(days) || days < 1) {
                alert("Days must be at least 1");
                return;
            }

            try {
                const res = await fetch('/api/users/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username, password, days })
                });

                if (res.ok) {
                    const data = await res.json();
                    showModal(data.user);
                    refreshData();
                    document.getElementById('u-name').value = '';
                    document.getElementById('u-pass').value = '';
                    document.getElementById('u-exp').value = '30';
                } else {
                    const msg = await res.text();
                    alert(msg || "Failed to create account. Please try again.");
                }
            } catch (e) {
                alert("Network error. Check your connection.");
            }
        }

        function showModal(u) {
            const content = `
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>IP Address :</span> <span class="text-blue-400">${ip}</span></div>
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>Hostname:</span> <span class="text-blue-400">${host}</span></div>
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>Username :</span> <span class="text-white font-bold">${u.username}</span></div>
                <div class="flex justify-between border-b border-gray-800 pb-2"><span>Password :</span> <span class="text-yellow-400 font-bold">${u.password}</span></div>
                <div class="flex justify-between"><span>Day left :</span> <span class="text-red-400 font-bold">${u.daysLeft} Days</span></div>
            `;
            document.getElementById('modal-content').innerHTML = content;
            document.getElementById('modal').style.display = 'flex';
            lucide.createIcons();
        }

        function copyText(text) {
            const value = String(text ?? '');
            navigator.clipboard.writeText(value).then(() => {
                alert("Copied!");
            }).catch(() => {
                const tempInput = document.createElement("textarea");
                tempInput.value = value;
                document.body.appendChild(tempInput);
                tempInput.select();
                document.execCommand("copy");
                document.body.removeChild(tempInput);
                alert("Copied!");
            });
        }

        function copyUserInfo(u) {
            const text = [
                `IP Address: ${ip}`,
                `Hostname: ${host}`,
                `Username: ${u.username}`,
                `Password: ${u.password}`,
                `Day left: ${u.daysLeft} Days`
            ].join('\n');
            copyText(text);
        }

        function copyModal() {
            const text = document.getElementById('modal-content').innerText;
            copyText(text);
        }

        async function deleteUser(id) {
            if (!confirm("Are you sure you want to delete this user?")) return;

            try {
                await fetch('/api/users/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ id })
                });
                refreshData();
            } catch (e) {
                alert("Delete failed");
            }
        }

        function render() {
            const containers = ['list-all', 'list-online', 'list-offline'];
            containers.forEach(c => document.getElementById(c).innerHTML = '');

            users.forEach(u => {
                const card = `
                    <div class="glass p-6 rounded-[2rem] border-t-4 ${u.status==='online'?'border-green-500':'border-blue-500'} relative shadow-lg">
                        <div class="flex justify-between items-start mb-4">
                            <div>
                                <h4 class="text-xl font-black text-white flex items-center gap-2">
                                    <i data-lucide="user" class="w-5 h-5 text-blue-400"></i> ${u.username}
                                </h4>
                                <span class="text-[10px] text-gray-500 font-mono">ID: ${u.id}</span>
                            </div>
                            <span class="px-3 py-1 rounded-full text-[10px] font-bold uppercase ${u.status==='online'?'bg-green-500/20 text-green-400':'bg-gray-800 text-gray-500'}">${u.status}</span>
                        </div>

                        <div class="space-y-2 text-xs bg-black/30 p-4 rounded-2xl mb-4 border border-gray-800/50">
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="globe" class="w-3 h-3"></i> IP address:</span> <span class="text-blue-400">${ip}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="link" class="w-3 h-3"></i> Hostname:</span> <span class="text-blue-400">${host}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="calendar" class="w-3 h-3"></i> Create Date:</span> <span>${u.createDate}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="calendar-x" class="w-3 h-3"></i> Expired Date:</span> <span class="text-red-400 font-bold">${u.expiryDate}</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="hourglass" class="w-3 h-3"></i> Day Left:</span> <span class="text-orange-400 font-bold">${u.daysLeft} Days</span></div>
                            <div class="flex justify-between"><span class="text-gray-500 flex items-center gap-1"><i data-lucide="key-round" class="w-3 h-3"></i> Password:</span> <span class="text-yellow-400 font-bold break-all">${u.password}</span></div>
                        </div>

                        <div class="flex flex-wrap gap-2 justify-between items-center pt-2">
                            <div class="text-blue-400 font-black flex items-center gap-1 text-sm"><i data-lucide="zap" class="w-4 h-4"></i> Total Flow (GB): <span class="text-white">${u.flow}</span></div>
                            <div class="flex gap-2">
                                <button class="p-2 hover:bg-cyan-500/20 rounded-lg text-cyan-400" onclick='copyText(${JSON.stringify(u.username)})' title="Copy Username"><i data-lucide="user-round-check" class="w-5 h-5"></i></button>
                                <button class="p-2 hover:bg-yellow-500/20 rounded-lg text-yellow-400" onclick='copyText(${JSON.stringify(u.password)})' title="Copy Password"><i data-lucide="copy" class="w-5 h-5"></i></button>
                                <button class="p-2 hover:bg-blue-500/20 rounded-lg text-blue-400" onclick='copyUserInfo(${JSON.stringify(u)})' title="Copy All"><i data-lucide="file-text" class="w-5 h-5"></i></button>
                                <button class="p-2 hover:bg-red-500/20 rounded-lg text-red-500" onclick="deleteUser('${u.id}')" title="Delete"><i data-lucide="trash-2" class="w-5 h-5"></i></button>
                            </div>
                        </div>
                    </div>
                `;
                document.getElementById('list-all').innerHTML += card;
                if (u.status === 'online') document.getElementById('list-online').innerHTML += card;
                else if (u.status === 'offline') document.getElementById('list-offline').innerHTML += card;
            });

            document.getElementById('stat-total').innerText = users.length;
            document.getElementById('stat-online').innerText = users.filter(u => u.status === 'online').length;
            document.getElementById('stat-offline').innerText = users.filter(u => u.status === 'offline').length;
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
            if (!file) return;

            const reader = new FileReader();
            reader.onload = async (e) => {
                try {
                    const res = await fetch('/api/restore', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: e.target.result
                    });

                    if (res.ok) {
                        refreshData();
                        alert("Restored Successfully!");
                    } else {
                        alert("Restore failed");
                    }
                } catch (err) {
                    alert("Restore error");
                }
            };
            reader.readAsText(file);
        }

        lucide.createIcons();
    </script>
</body>
</html>
EOF

# Replace placeholders safely
export HOST_NAME="$host_name"
export IP_ADDR="$ip_addr"

python3 - <<'PY'
from pathlib import Path
import json, os

path = Path("/etc/zivpn/index.html")
txt = path.read_text(encoding="utf-8")
txt = txt.replace("__HOST_NAME__", json.dumps(os.environ["HOST_NAME"]))
txt = txt.replace("__IP_ADDR__", json.dumps(os.environ["IP_ADDR"]))
path.write_text(txt, encoding="utf-8")
PY

# --- Node.js Backend Server ---
cat <<'EOF' > /etc/zivpn/panel.js
const http = require('http');
const fs = require('fs');

const DB_PATH = '/etc/zivpn/data/users.json';
const CRED_PATH = '/etc/zivpn/credentials.json';
const CONFIG_PATH = '/etc/zivpn/config.json';
const INDEX_PATH = '/etc/zivpn/index.html';

const DEFAULT_CONFIG = {
    listen: ':5667',
    cert: '/etc/zivpn/zivpn.crt',
    key: '/etc/zivpn/zivpn.key',
    obfs: 'zivpn',
    auth: {
        mode: 'passwords',
        config: ['zi']
    },
    config: ['zi']
};

function readJson(path, fallback) {
    try {
        if (!fs.existsSync(path)) return fallback;
        const raw = fs.readFileSync(path, 'utf8').trim();
        if (!raw) return fallback;
        return JSON.parse(raw);
    } catch (e) {
        return fallback;
    }
}

function writeJson(path, data) {
    fs.writeFileSync(path, JSON.stringify(data, null, 2));
}

function ensureFiles() {
    if (!fs.existsSync('/etc/zivpn')) fs.mkdirSync('/etc/zivpn', { recursive: true });
    if (!fs.existsSync('/etc/zivpn/data')) fs.mkdirSync('/etc/zivpn/data', { recursive: true });

    if (!fs.existsSync(DB_PATH) || fs.readFileSync(DB_PATH, 'utf8').trim() === '') {
        writeJson(DB_PATH, []);
    }

    if (!fs.existsSync(CONFIG_PATH) || fs.readFileSync(CONFIG_PATH, 'utf8').trim() === '') {
        writeJson(CONFIG_PATH, DEFAULT_CONFIG);
    } else {
        const current = readJson(CONFIG_PATH, DEFAULT_CONFIG);
        if (!current.auth || !Array.isArray(current.auth.config)) {
            const oldPasswords = Array.isArray(current.config) ? current.config : ['zi'];
            const upgraded = {
                ...DEFAULT_CONFIG,
                ...current,
                auth: {
                    mode: 'passwords',
                    config: oldPasswords.length ? [...new Set(oldPasswords.map(v => String(v).trim()).filter(Boolean))] : ['zi']
                },
                config: oldPasswords.length ? [...new Set(oldPasswords.map(v => String(v).trim()).filter(Boolean))] : ['zi']
            };
            writeJson(CONFIG_PATH, upgraded);
        }
    }

    if (!fs.existsSync(CRED_PATH) || fs.readFileSync(CRED_PATH, 'utf8').trim() === '') {
        writeJson(CRED_PATH, { username: 'admin', password: 'admin' });
    }
}

function getConfig() {
    const cfg = readJson(CONFIG_PATH, DEFAULT_CONFIG);

    if (!cfg.auth || !Array.isArray(cfg.auth.config)) {
        const oldPasswords = Array.isArray(cfg.config) ? cfg.config : ['zi'];
        return {
            ...DEFAULT_CONFIG,
            ...cfg,
            auth: {
                mode: 'passwords',
                config: oldPasswords.length ? [...new Set(oldPasswords.map(v => String(v).trim()).filter(Boolean))] : ['zi']
            },
            config: oldPasswords.length ? [...new Set(oldPasswords.map(v => String(v).trim()).filter(Boolean))] : ['zi']
        };
    }

    cfg.auth.mode = 'passwords';
    cfg.auth.config = [...new Set(cfg.auth.config.map(v => String(v).trim()).filter(Boolean))];
    if (cfg.auth.config.length === 0) cfg.auth.config = ['zi'];

    cfg.config = Array.isArray(cfg.config)
        ? [...new Set(cfg.config.map(v => String(v).trim()).filter(Boolean))]
        : [...cfg.auth.config];

    if (cfg.config.length === 0) cfg.config = ['zi'];
    return cfg;
}

function setPasswordList(passwords) {
    const cleaned = [...new Set(passwords.map(v => String(v).trim()).filter(Boolean))];
    const cfg = getConfig();
    cfg.auth = cfg.auth || {};
    cfg.auth.mode = 'passwords';
    cfg.auth.config = cleaned.length ? cleaned : ['zi'];
    cfg.config = cleaned.length ? cleaned : ['zi'];
    writeJson(CONFIG_PATH, cfg);
}

function getPasswordList() {
    const cfg = getConfig();
    if (Array.isArray(cfg.auth?.config) && cfg.auth.config.length) return cfg.auth.config;
    if (Array.isArray(cfg.config) && cfg.config.length) return cfg.config;
    return [];
}

ensureFiles();

function send(res, code, type, body) {
    res.writeHead(code, { 'Content-Type': type });
    res.end(body);
}

function serveIndex(res) {
    fs.readFile(INDEX_PATH, (err, data) => {
        if (err) return send(res, 500, 'text/plain', 'Frontend file missing');
        send(res, 200, 'text/html', data);
    });
}

const server = http.createServer((req, res) => {
    let body = '';

    req.on('data', chunk => {
        body += chunk;
        if (body.length > 10 * 1024 * 1024) {
            send(res, 413, 'text/plain', 'Payload too large');
            req.destroy();
        }
    });

    req.on('end', () => {
        try {
            if (req.url === '/api/login' && req.method === 'POST') {
                try {
                    const { u, p } = JSON.parse(body || '{}');
                    const creds = readJson(CRED_PATH, { username: '', password: '' });

                    if (u === creds.username && p === creds.password) {
                        return send(res, 200, 'text/plain', 'OK');
                    }
                    return send(res, 401, 'text/plain', 'Fail');
                } catch (e) {
                    return send(res, 400, 'text/plain', 'Bad Request');
                }
            }

            if (req.url === '/api/users' && req.method === 'GET') {
                const users = readJson(DB_PATH, []);
                return send(res, 200, 'application/json', JSON.stringify(users));
            }

            if (req.url === '/api/users/add' && req.method === 'POST') {
                try {
                    const data = JSON.parse(body || '{}');
                    const username = String(data.username || '').trim();
                    const password = String(data.password || '').trim();
                    let days = parseInt(data.days, 10);

                    if (!username || !password) {
                        return send(res, 400, 'text/plain', 'Missing Fields');
                    }

                    if (Number.isNaN(days) || days < 1) days = 30;

                    let users = readJson(DB_PATH, []);
                    const expDate = new Date();
                    expDate.setDate(expDate.getDate() + days);

                    const newUser = {
                        id: Math.random().toString(36).substr(2, 6).toUpperCase(),
                        username,
                        password,
                        createDate: new Date().toLocaleDateString(),
                        expiryDate: expDate.toLocaleDateString(),
                        daysLeft: days,
                        flow: (Math.random() * 2).toFixed(2),
                        status: 'offline'
                    };

                    users.push(newUser);
                    writeJson(DB_PATH, users);

                    const passwords = getPasswordList();
                    passwords.push(password);
                    setPasswordList(passwords);

                    return send(res, 200, 'application/json', JSON.stringify({ user: newUser }));
                } catch (e) {
                    return send(res, 400, 'text/plain', 'Invalid JSON');
                }
            }

            if (req.url === '/api/users/delete' && req.method === 'POST') {
                try {
                    const { id } = JSON.parse(body || '{}');
                    let users = readJson(DB_PATH, []);
                    const user = users.find(u => u.id === id);

                    if (user) {
                        const passwords = getPasswordList().filter(p => p !== String(user.password || '').trim());
                        setPasswordList(passwords);
                    }

                    users = users.filter(u => u.id !== id);
                    writeJson(DB_PATH, users);

                    return send(res, 200, 'text/plain', 'Deleted');
                } catch (e) {
                    return send(res, 400, 'text/plain', 'Bad Request');
                }
            }

            if (req.url === '/api/backup' && req.method === 'GET') {
                const users = readJson(DB_PATH, []);
                res.writeHead(200, {
                    'Content-Type': 'application/json',
                    'Content-Disposition': 'attachment; filename=zivpn_backup.json'
                });
                return res.end(JSON.stringify(users, null, 2));
            }

            if (req.url === '/api/restore' && req.method === 'POST') {
                try {
                    const restoredUsers = JSON.parse(body || '[]');
                    if (!Array.isArray(restoredUsers)) {
                        return send(res, 400, 'text/plain', 'Restore file must be an array');
                    }

                    writeJson(DB_PATH, restoredUsers);

                    const passwords = restoredUsers
                        .map(u => String(u && u.password ? u.password : '').trim())
                        .filter(Boolean);

                    setPasswordList(passwords);

                    return send(res, 200, 'text/plain', 'Restored');
                } catch (e) {
                    return send(res, 400, 'text/plain', 'Invalid Restore File');
                }
            }

            return serveIndex(res);
        } catch (e) {
            return send(res, 500, 'text/plain', 'Server error');
        }
    });
});

server.listen(8080, '0.0.0.0');
EOF

# --- Nginx Setup ---
rm -f /etc/nginx/sites-enabled/default
cat <<'EOF' > /etc/nginx/sites-available/zivpn
server {
    listen 81;
    server_name _;

    add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0" always;
    add_header Pragma "no-cache" always;
    add_header Expires "0" always;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF
ln -sf /etc/nginx/sites-available/zivpn /etc/nginx/sites-enabled/zivpn

nginx -t

# --- Systemd Services ---
cat <<'EOF' > /etc/systemd/system/zivpn.service
[Unit]
Description=Zivpn UDP Server
After=network.target

[Service]
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
User=root
WorkingDirectory=/etc/zivpn

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > /etc/systemd/system/zivpn-panel.service
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
systemctl restart zivpn || true
systemctl restart zivpn-panel || true
systemctl restart nginx

# Firewall settings
ufw allow 81/tcp || true
ufw allow 5667/udp || true
ufw allow 6000:19999/udp || true

clear
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}      ZIVPN ULTIMATE PANEL FIXED & READY       ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e " Dashboard: http://$host_name:81"
echo -e " Admin Username: $admin_user"
echo -e " Admin Password: $admin_pass"
echo -e "${YELLOW}Fix Applied: password sync to auth.config + config, password shown in cards, copy buttons added, cache disabled.${NC}"
echo -e "${GREEN}===============================================${NC}"

#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

clear
echo "=== Zivpn UDP + Admin Panel Installer ==="
echo

read -rp "Admin Username: " ADMIN_USER
while true; do
  read -rsp "Admin Password: " ADMIN_PASS
  echo
  read -rsp "Confirm Password: " ADMIN_PASS2
  echo
  [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] && break
  echo "Passwords do not match. Try again."
done
read -rp "Hostname: " PANEL_HOSTNAME
read -rp "Panel Title [Zivpn Admin Panel]: " PANEL_TITLE
PANEL_TITLE="${PANEL_TITLE:-Zivpn Admin Panel}"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ZIVPN_BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64" ;;
  aarch64|arm64) ZIVPN_BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64" ;;
  armv7l|armv6l) ZIVPN_BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "[1/9] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip nginx openssl wget curl ufw iptables-persistent
python3 -m pip install --upgrade pip >/dev/null
python3 -m pip install werkzeug >/dev/null

echo "[2/9] Installing Zivpn binary..."
systemctl stop zivpn.service >/dev/null 2>&1 || true
mkdir -p /etc/zivpn /var/lib/zivpn-panel /etc/zivpn-panel /opt/zivpn-panel
wget -q "$ZIVPN_BIN_URL" -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

echo "[3/9] Creating certificates..."
if [ ! -f /etc/zivpn/zivpn.key ] || [ ! -f /etc/zivpn/zivpn.crt ]; then
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=US/ST=California/L=Los Angeles/O=Zivpn/OU=Panel/CN=${PANEL_HOSTNAME}" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

echo "[4/9] Writing default Zivpn config..."
cat > /etc/zivpn/config.json <<'EOF'
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  }
}
EOF

echo "[5/9] Writing panel application..."
cat > /opt/zivpn-panel/app.py <<'PYAPP'
import io
import json
import os
import sqlite3
import subprocess
import tarfile
import secrets
from datetime import datetime, date
from pathlib import Path

from flask import Flask, abort, jsonify, redirect, render_template_string, request, send_file, session, url_for
from werkzeug.security import check_password_hash

DB_PATH = Path("/var/lib/zivpn-panel/panel.db")
ZIVPN_DIR = Path("/etc/zivpn")
CONFIG_PATH = ZIVPN_DIR / "config.json"
CERT_PATH = ZIVPN_DIR / "zivpn.crt"
KEY_PATH = ZIVPN_DIR / "zivpn.key"
ENV_PATH = Path("/etc/zivpn-panel/panel.env")

def load_env(path: Path):
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

ENV = load_env(ENV_PATH)
ADMIN_USER = ENV.get("ADMIN_USER", "admin")
ADMIN_PASS_HASH = ENV.get("ADMIN_PASS_HASH", "")
PANEL_HOSTNAME = ENV.get("PANEL_HOSTNAME", "localhost")
PANEL_TITLE = ENV.get("PANEL_TITLE", "Zivpn Admin Panel")
SESSION_SECRET = ENV.get("SESSION_SECRET", secrets.token_hex(32))

app = Flask(__name__)
app.secret_key = SESSION_SECRET
app.config["MAX_CONTENT_LENGTH"] = 128 * 1024 * 1024

TEMPLATE = r"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }}</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/sweetalert2@11"></script>
<style>
:root { --bg1:#0b1220; --bg2:#111a2e; --card:#121c31; --line:#24314d; --text:#e9eefc; --muted:#9db0d0; }
body { background: radial-gradient(circle at top, #15213a 0, #0b1220 55%, #08111d 100%); color: var(--text); min-height:100vh; }
.navbar, .card, .modal-content, .dropdown-menu { background: rgba(14,22,39,.96) !important; border:1px solid var(--line) !important; color: var(--text); }
.card { box-shadow: 0 10px 30px rgba(0,0,0,.25); border-radius: 22px; }
.metric { overflow:hidden; position:relative; }
.metric::after { content:""; position:absolute; inset:auto -40% -60% auto; width:180px; height:180px; border-radius:50%; opacity:.16; background: currentColor; filter: blur(2px); }
.metric .num { font-size: 2rem; font-weight: 800; letter-spacing: .2px; }
.pulse-blue { color:#60a5fa; animation:pulseGlow 2s infinite; }
.pulse-green { color:#34d399; animation:pulseGlow 2s infinite; }
.pulse-red { color:#f87171; animation:pulseGlow 2s infinite; }
.pulse-gold { color:#fbbf24; animation:pulseGlow 2s infinite; }
.pulse-purple { color:#c084fc; animation:pulseGlow 2s infinite; }
@keyframes pulseGlow { 0%,100%{transform:translateY(0);filter:drop-shadow(0 0 0 rgba(255,255,255,0));} 50%{transform:translateY(-2px);filter:drop-shadow(0 0 16px currentColor);} }
.nav-tabs .nav-link { color: var(--muted); border:0; border-radius:16px 16px 0 0; margin-right:6px; }
.nav-tabs .nav-link.active { background: linear-gradient(135deg, #1d2d52, #12203f); color: #fff; border:1px solid var(--line); border-bottom:0; }
.table { color: var(--text); }
.table thead th { border-color: var(--line); color: var(--muted); }
.table td, .table th { border-color: var(--line); vertical-align: middle; }
.form-control, .form-select { background:#0e1730; color:var(--text); border:1px solid #32415f; }
.form-control:focus, .form-select:focus { border-color:#5b8cff; box-shadow:0 0 0 .2rem rgba(91,140,255,.15); background:#0e1730; color:var(--text); }
.badge-soft { background: rgba(255,255,255,.08); border:1px solid rgba(255,255,255,.08); }
.small-muted { color: var(--muted); font-size: .92rem; }
.copy-btn { border:1px solid #334767; background:#0e1730; color:#fff; border-radius:999px; }
.copy-btn:hover { background:#18284a; }
.fade-in { animation:fadeIn .25s ease; }
@keyframes fadeIn { from {opacity:0; transform: translateY(10px);} to {opacity:1; transform:none;} }
</style>
</head>
<body>
<nav class="navbar navbar-expand-lg sticky-top">
  <div class="container-fluid px-4">
    <a class="navbar-brand fw-bold text-white" href="#"><i class="fa-solid fa-shield-halved me-2"></i>{{ title }}</a>
    <div class="ms-auto text-end">
      <div class="fw-semibold">{{ hostname }}</div>
      <div class="small-muted">Panel Port 8000</div>
    </div>
  </div>
</nav>

<div class="container-fluid p-4">
  {% if error %}
    <div class="alert alert-danger">{{ error }}</div>
  {% endif %}
  {% if not logged_in %}
  <div class="row justify-content-center mt-5">
    <div class="col-md-4">
      <div class="card p-4">
        <h3 class="mb-3"><i class="fa-solid fa-right-to-bracket me-2"></i>Admin Login</h3>
        <form method="post" action="{{ url_for('login') }}">
          <div class="mb-3">
            <label class="form-label">Username</label>
            <input class="form-control" name="username" required>
          </div>
          <div class="mb-3">
            <label class="form-label">Password</label>
            <input class="form-control" name="password" type="password" required>
          </div>
          <button class="btn btn-primary w-100"><i class="fa-solid fa-lock me-2"></i>Sign in</button>
        </form>
      </div>
    </div>
  </div>
  {% else %}
  <ul class="nav nav-tabs mt-2" id="panelTabs" role="tablist">
    <li class="nav-item"><button class="nav-link active" data-bs-toggle="tab" data-bs-target="#dash" type="button"><i class="fa-solid fa-chart-line me-2"></i>Dashboard</button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#users" type="button"><i class="fa-solid fa-users me-2"></i>Users</button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#add" type="button"><i class="fa-solid fa-circle-plus me-2"></i>Add Account</button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#backup" type="button"><i class="fa-solid fa-database me-2"></i>Backup / Restore</button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#settings" type="button"><i class="fa-solid fa-gear me-2"></i>Settings</button></li>
  </ul>

  <div class="tab-content pt-3">
    <div class="tab-pane fade show active" id="dash">
      <div class="row g-3">
        <div class="col-md-4"><div class="card metric pulse-blue p-4"><div class="small-muted">Total Users</div><div class="num">{{ stats.total_users }}</div><div><i class="fa-solid fa-users"></i></div></div></div>
        <div class="col-md-4"><div class="card metric pulse-green p-4"><div class="small-muted">Online</div><div class="num">{{ stats.online }}</div><div><i class="fa-solid fa-signal"></i></div></div></div>
        <div class="col-md-4"><div class="card metric pulse-red p-4"><div class="small-muted">Offline</div><div class="num">{{ stats.offline }}</div><div><i class="fa-solid fa-circle-xmark"></i></div></div></div>
        <div class="col-md-6"><div class="card metric pulse-gold p-4"><div class="small-muted">Today Sales (THB)</div><div class="num">{{ stats.today_sales }}</div><div><i class="fa-solid fa-coins"></i></div></div></div>
        <div class="col-md-6"><div class="card metric pulse-purple p-4"><div class="small-muted">Total Sales (THB)</div><div class="num">{{ stats.total_sales }}</div><div><i class="fa-solid fa-wallet"></i></div></div></div>
      </div>
      <div class="card mt-3 p-3">
        <div class="d-flex justify-content-between align-items-center mb-2">
          <h5 class="mb-0"><i class="fa-solid fa-list me-2"></i>Latest Users</h5>
          <span class="badge badge-soft">Hostname: {{ hostname }}</span>
        </div>
        <div class="row g-3">
          {% for u in users %}
          <div class="col-md-6 col-xl-4">
            <div class="card p-3 h-100 fade-in">
              <div class="d-flex justify-content-between align-items-start">
                <div>
                  <div class="fw-bold fs-5"><i class="fa-solid fa-user me-2"></i>{{ u.username }}</div>
                  <div class="small-muted">{{ u.expired_date }} • Day left: {{ u.day_left }}</div>
                </div>
                <span class="badge {% if u.is_online %}text-bg-success{% else %}text-bg-secondary{% endif %}">{{ 'Online' if u.is_online else 'Offline' }}</span>
              </div>
              <hr>
              <div class="small-muted mb-2"><i class="fa-solid fa-circle-nodes me-2"></i>IP address: <span id="ip-{{u.id}}">{{ u.ip_address }}</span>
                <button class="btn btn-sm copy-btn ms-2" onclick="copyText({{ u.ip_address|tojson }})"><i class="fa-regular fa-copy"></i></button>
              </div>
              <div class="small-muted mb-2"><i class="fa-solid fa-server me-2"></i>Hostname: <span id="host-{{u.id}}">{{ u.hostname }}</span>
                <button class="btn btn-sm copy-btn ms-2" onclick="copyText({{ u.hostname|tojson }})"><i class="fa-regular fa-copy"></i></button>
              </div>
              <div class="small-muted mb-2"><i class="fa-solid fa-id-card me-2"></i>Username: <span id="usr-{{u.id}}">{{ u.username }}</span>
                <button class="btn btn-sm copy-btn ms-2" onclick="copyText({{ u.username|tojson }})"><i class="fa-regular fa-copy"></i></button>
              </div>
              <div class="small-muted mb-2"><i class="fa-solid fa-key me-2"></i>Password: <span id="pwd-{{u.id}}">{{ u.password }}</span>
                <button class="btn btn-sm copy-btn ms-2" onclick="copyText({{ u.password|tojson }})"><i class="fa-regular fa-copy"></i></button>
              </div>
              <div class="small-muted mb-2"><i class="fa-regular fa-calendar me-2"></i>Create Date: {{ u.created_at }}</div>
              <div class="small-muted mb-2"><i class="fa-regular fa-calendar-check me-2"></i>Expired Date: {{ u.expired_date }}</div>
              <div class="small-muted mb-2"><i class="fa-solid fa-gauge-high me-2"></i>Total Flow (GB): {{ u.total_flow }}</div>
              <div class="d-flex gap-2 mt-2">
                <button class="btn btn-outline-info btn-sm" onclick="loadEdit({{ u.id }})"><i class="fa-solid fa-pen me-1"></i>Edit</button>
                <button class="btn btn-outline-danger btn-sm" onclick="deleteUser({{ u.id }})"><i class="fa-solid fa-trash me-1"></i>Delete</button>
              </div>
            </div>
          </div>
          {% endfor %}
        </div>
      </div>
    </div>

    <div class="tab-pane fade" id="users">
      <div class="card p-3">
        <h5 class="mb-3"><i class="fa-solid fa-users-gear me-2"></i>All Accounts</h5>
        <div class="table-responsive">
        <table class="table align-middle">
          <thead><tr><th>ID</th><th>Username</th><th>Password</th><th>Price</th><th>Created</th><th>Expired</th><th>Day Left</th><th>Flow GB</th><th>Action</th></tr></thead>
          <tbody>
          {% for u in users %}
            <tr>
              <td>{{ u.id }}</td>
              <td>{{ u.username }}</td>
              <td>{{ u.password }}</td>
              <td>{{ u.price }}</td>
              <td>{{ u.created_at }}</td>
              <td>{{ u.expired_date }}</td>
              <td>{{ u.day_left }}</td>
              <td>{{ u.total_flow }}</td>
              <td>
                <button class="btn btn-sm btn-outline-info" onclick="loadEdit({{ u.id }})"><i class="fa-solid fa-pen"></i></button>
                <button class="btn btn-sm btn-outline-danger" onclick="deleteUser({{ u.id }})"><i class="fa-solid fa-trash"></i></button>
              </td>
            </tr>
          {% endfor %}
          </tbody>
        </table>
        </div>
      </div>
    </div>

    <div class="tab-pane fade" id="add">
      <div class="card p-4">
        <h5 class="mb-3"><i class="fa-solid fa-circle-plus me-2"></i>Add User / Add Account</h5>
        <form id="addForm">
          <div class="row g-3">
            <div class="col-md-6"><label class="form-label">Username</label><input class="form-control" name="username" required></div>
            <div class="col-md-6"><label class="form-label">Password</label><input class="form-control" name="password" required></div>
            <div class="col-md-4"><label class="form-label">Price (THB)</label><input class="form-control" name="price" type="number" step="0.01" required></div>
            <div class="col-md-4"><label class="form-label">Expired Date</label><input class="form-control" name="expired_date" type="date" required></div>
            <div class="col-md-4"><label class="form-label">IP Address</label><input class="form-control" name="ip_address" placeholder="Optional"></div>
            <div class="col-md-12"><label class="form-label">Hostname</label><input class="form-control" name="hostname" value="{{ hostname }}"></div>
          </div>
          <button class="btn btn-primary mt-3"><i class="fa-solid fa-floppy-disk me-2"></i>Add Account</button>
        </form>
      </div>
    </div>

    <div class="tab-pane fade" id="backup">
      <div class="row g-3">
        <div class="col-md-6">
          <div class="card p-4 h-100">
            <h5><i class="fa-solid fa-download me-2"></i>Backup</h5>
            <p class="small-muted">Download database, config, certificate, and key in one archive.</p>
            <a class="btn btn-success" href="{{ url_for('backup') }}"><i class="fa-solid fa-cloud-arrow-down me-2"></i>Download Backup</a>
          </div>
        </div>
        <div class="col-md-6">
          <div class="card p-4 h-100">
            <h5><i class="fa-solid fa-upload me-2"></i>Restore</h5>
            <form method="post" action="{{ url_for('restore') }}" enctype="multipart/form-data">
              <input class="form-control mb-3" type="file" name="backup_file" accept=".tar.gz,.tgz" required>
              <button class="btn btn-warning"><i class="fa-solid fa-rotate-right me-2"></i>Restore Backup</button>
            </form>
          </div>
        </div>
      </div>
    </div>

    <div class="tab-pane fade" id="settings">
      <div class="card p-4">
        <h5 class="mb-3"><i class="fa-solid fa-gear me-2"></i>Settings</h5>
        <div class="row g-3">
          <div class="col-md-4"><div class="p-3 border rounded-4">Admin Username<br><b>{{ admin_user }}</b></div></div>
          <div class="col-md-4"><div class="p-3 border rounded-4">Hostname<br><b>{{ hostname }}</b></div></div>
          <div class="col-md-4"><div class="p-3 border rounded-4">Zivpn Config<br><b>{{ config_path }}</b></div></div>
        </div>
        <div class="mt-3 small-muted">Zivpn uses password auth in <code>auth.config</code>; this panel syncs each user password into the server config.</div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="editModal" tabindex="-1">
    <div class="modal-dialog modal-lg modal-dialog-centered">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title"><i class="fa-solid fa-pen-to-square me-2"></i>Edit User</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
        </div>
        <div class="modal-body">
          <form id="editForm">
            <input type="hidden" name="id" id="edit_id">
            <div class="row g-3">
              <div class="col-md-6"><label class="form-label">Username</label><input class="form-control" name="username" id="edit_username" required></div>
              <div class="col-md-6"><label class="form-label">Password</label><input class="form-control" name="password" id="edit_password" required></div>
              <div class="col-md-4"><label class="form-label">Price (THB)</label><input class="form-control" name="price" id="edit_price" type="number" step="0.01" required></div>
              <div class="col-md-4"><label class="form-label">Expired Date</label><input class="form-control" name="expired_date" id="edit_expired_date" type="date" required></div>
              <div class="col-md-4"><label class="form-label">IP Address</label><input class="form-control" name="ip_address" id="edit_ip_address"></div>
              <div class="col-md-12"><label class="form-label">Hostname</label><input class="form-control" name="hostname" id="edit_hostname" required></div>
              <div class="col-md-4"><label class="form-label">Total Flow (GB)</label><input class="form-control" name="total_flow" id="edit_total_flow" type="number" step="0.01"></div>
              <div class="col-md-4"><label class="form-label">Active</label>
                <select class="form-select" name="active" id="edit_active">
                  <option value="1">Active</option>
                  <option value="0">Disabled</option>
                </select>
              </div>
            </div>
          </form>
        </div>
        <div class="modal-footer">
          <button class="btn btn-primary" onclick="saveEdit()"><i class="fa-solid fa-floppy-disk me-2"></i>Save</button>
        </div>
      </div>
    </div>
  </div>
  {% endif %}
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script>
async function copyText(text){
  try { await navigator.clipboard.writeText(text); Swal.fire({icon:'success', title:'Copied', text:text, timer:1200, showConfirmButton:false}); }
  catch(e){ Swal.fire('Copy failed', String(e), 'error'); }
}
function showMsg(title, html, icon='success'){
  Swal.fire({title, html, icon, confirmButtonText:'OK'});
}
document.getElementById('addForm')?.addEventListener('submit', async (e)=>{
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target).entries());
  const res = await fetch('/api/users', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(data)});
  const j = await res.json();
  if(j.ok){
    showMsg('Generate Account Successfuly', `
      <div class="text-start">
        <div><b>IP Address :</b> ${j.user.ip_address}</div>
        <div><b>Hostname :</b> ${j.user.hostname}</div>
        <div><b>Username :</b> ${j.user.username}</div>
        <div><b>Password :</b> ${j.user.password}</div>
        <div><b>Day left :</b> ${j.user.day_left}</div>
      </div>`, 'success');
    setTimeout(()=>location.reload(), 900);
  }else{
    showMsg('Error', j.error || 'Failed', 'error');
  }
});
async function loadEdit(id){
  const res = await fetch(`/api/users/${id}`);
  const j = await res.json();
  if(!j.ok){ showMsg('Error', j.error || 'Failed', 'error'); return; }
  const u = j.user;
  edit_id.value = u.id;
  edit_username.value = u.username;
  edit_password.value = u.password;
  edit_price.value = u.price;
  edit_expired_date.value = u.expired_date;
  edit_ip_address.value = u.ip_address;
  edit_hostname.value = u.hostname;
  edit_total_flow.value = u.total_flow;
  edit_active.value = u.active ? '1' : '0';
  new bootstrap.Modal(document.getElementById('editModal')).show();
}
async function saveEdit(){
  const form = document.getElementById('editForm');
  const data = Object.fromEntries(new FormData(form).entries());
  const id = data.id;
  const res = await fetch(`/api/users/${id}`, {method:'PUT', headers:{'Content-Type':'application/json'}, body: JSON.stringify(data)});
  const j = await res.json();
  if(j.ok){ showMsg('Saved', 'User updated successfully', 'success'); setTimeout(()=>location.reload(), 800); }
  else showMsg('Error', j.error || 'Failed', 'error');
}
async function deleteUser(id){
  const ok = await Swal.fire({title:'Delete user?', text:'This will remove the account from panel and Zivpn config.', icon:'warning', showCancelButton:true, confirmButtonText:'Delete'});
  if(!ok.isConfirmed) return;
  const res = await fetch(`/api/users/${id}`, {method:'DELETE'});
  const j = await res.json();
  if(j.ok){ showMsg('Deleted', 'User deleted successfully', 'success'); setTimeout(()=>location.reload(), 800); }
  else showMsg('Error', j.error || 'Failed', 'error');
}
</script>
</body>
</html>
"""

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            password TEXT NOT NULL,
            price REAL NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            expired_date TEXT NOT NULL,
            ip_address TEXT NOT NULL DEFAULT '',
            hostname TEXT NOT NULL DEFAULT '',
            total_flow REAL NOT NULL DEFAULT 0,
            active INTEGER NOT NULL DEFAULT 1
        )
        """)
        conn.commit()

def today_str():
    return date.today().isoformat()

def parse_dt(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except Exception:
        return None

def days_left(expired_date):
    d = parse_dt(expired_date)
    if not d:
        return 0
    return max(0, (d - date.today()).days)

def local_ip():
    try:
        out = subprocess.check_output(["bash", "-lc", "hostname -I | awk '{print $1}'"], text=True).strip()
        return out or ""
    except Exception:
        return ""

def read_users():
    with db() as conn:
        rows = conn.execute("SELECT * FROM users ORDER BY id DESC").fetchall()
    users = []
    for r in rows:
        d = dict(r)
        d["day_left"] = days_left(d["expired_date"])
        d["is_online"] = bool(d["active"]) and d["day_left"] > 0
        users.append(d)
    return users

def ensure_config():
    ZIVPN_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(json.dumps({
            "listen": ":5667",
            "cert": str(CERT_PATH),
            "key": str(KEY_PATH),
            "obfs": "zivpn",
            "auth": {"mode": "passwords", "config": ["zi"]}
        }, indent=2))

def sync_zivpn():
    ensure_config()
    users = read_users()
    passwords = []
    seen = set()
    for u in users:
        if not u["active"]:
            continue
        pw = u["password"]
        if pw not in seen:
            seen.add(pw)
            passwords.append(pw)
    if not passwords:
        passwords = ["zi"]
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    cfg.setdefault("auth", {})
    cfg["auth"]["mode"] = "passwords"
    cfg["auth"]["config"] = passwords
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    subprocess.run(["systemctl", "restart", "zivpn.service"], check=False)

def require_login():
    return session.get("admin") is True

@app.route("/", methods=["GET"])
def index():
    init_db()
    users = read_users()
    stats = {
        "total_users": len(users),
        "online": sum(1 for u in users if u["is_online"]),
        "offline": sum(1 for u in users if not u["is_online"]),
        "today_sales": f'{sum((u["price"] or 0) for u in users if u["created_at"][:10] == today_str()):.2f}',
        "total_sales": f'{sum((u["price"] or 0) for u in users):.2f}',
    }
    return render_template_string(TEMPLATE, title=PANEL_TITLE, hostname=PANEL_HOSTNAME, logged_in=require_login(),
                                  stats=stats, users=users[:24], admin_user=ADMIN_USER, config_path=str(CONFIG_PATH), error=None)

@app.route("/login", methods=["POST"])
def login():
    username = request.form.get("username", "")
    password = request.form.get("password", "")
    if username != ADMIN_USER or not ADMIN_PASS_HASH or not check_password_hash(ADMIN_PASS_HASH, password):
        return render_template_string(TEMPLATE, title=PANEL_TITLE, hostname=PANEL_HOSTNAME, logged_in=False,
                                      stats={}, users=[], admin_user=ADMIN_USER, config_path=str(CONFIG_PATH),
                                      error="Invalid username or password")
    session["admin"] = True
    return redirect(url_for("index"))

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("index"))

@app.route("/api/users", methods=["GET", "POST"])
def api_users():
    if not require_login():
        return jsonify(ok=False, error="Unauthorized"), 401
    init_db()
    if request.method == "GET":
        return jsonify(ok=True, users=read_users())
    data = request.get_json(force=True)
    required = ["username", "password", "price", "expired_date"]
    for k in required:
        if not data.get(k):
            return jsonify(ok=False, error=f"Missing {k}"), 400
    ip_address = (data.get("ip_address") or local_ip()).strip()
    hostname = (data.get("hostname") or PANEL_HOSTNAME).strip()
    created_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    expired_date = str(data["expired_date"])
    with db() as conn:
        conn.execute(
            """INSERT INTO users (username,password,price,created_at,expired_date,ip_address,hostname,total_flow,active)
               VALUES (?,?,?,?,?,?,?,?,1)""",
            (data["username"].strip(), data["password"].strip(), float(data["price"]), created_at, expired_date, ip_address, hostname, float(data.get("total_flow") or 0))
        )
        conn.commit()
    sync_zivpn()
    u = read_users()[0]
    return jsonify(ok=True, user=u)

@app.route("/api/users/<int:user_id>", methods=["GET", "PUT", "DELETE"])
def api_user(user_id):
    if not require_login():
        return jsonify(ok=False, error="Unauthorized"), 401
    init_db()
    with db() as conn:
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            return jsonify(ok=False, error="User not found"), 404
        if request.method == "GET":
            d = dict(row)
            d["day_left"] = days_left(d["expired_date"])
            d["is_online"] = bool(d["active"]) and d["day_left"] > 0
            return jsonify(ok=True, user=d)
        if request.method == "DELETE":
            conn.execute("DELETE FROM users WHERE id=?", (user_id,))
            conn.commit()
            sync_zivpn()
            return jsonify(ok=True)
        data = request.get_json(force=True)
        conn.execute(
            """UPDATE users
               SET username=?, password=?, price=?, expired_date=?, ip_address=?, hostname=?, total_flow=?, active=?
               WHERE id=?""",
            (data.get("username","").strip(), data.get("password","").strip(), float(data.get("price") or 0),
             data.get("expired_date",""), data.get("ip_address","").strip(), data.get("hostname","").strip(),
             float(data.get("total_flow") or 0), 1 if str(data.get("active","1")) == "1" else 0, user_id)
        )
        conn.commit()
    sync_zivpn()
    return jsonify(ok=True)

@app.route("/backup")
def backup():
    if not require_login():
        abort(401)
    init_db()
    mem = io.BytesIO()
    with tarfile.open(fileobj=mem, mode="w:gz") as tar:
        for path in [DB_PATH, CONFIG_PATH, CERT_PATH, KEY_PATH, ENV_PATH]:
            if path.exists():
                tar.add(path, arcname=str(path).lstrip("/"))
    mem.seek(0)
    filename = f"zivpn_panel_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}.tar.gz"
    return send_file(mem, as_attachment=True, download_name=filename, mimetype="application/gzip")

@app.route("/restore", methods=["POST"])
def restore():
    if not require_login():
        abort(401)
    f = request.files.get("backup_file")
    if not f:
        return "No file", 400
    data = f.read()
    mem = io.BytesIO(data)
    with tarfile.open(fileobj=mem, mode="r:gz") as tar:
        for member in tar.getmembers():
            if not member.name.startswith(("var/lib/zivpn-panel/", "etc/zivpn/", "etc/zivpn-panel/")):
                continue
            tar.extract(member, path="/")
    sync_zivpn()
    return redirect(url_for("index"))

if __name__ == "__main__":
    init_db()
    ensure_config()
    app.run(host="127.0.0.1", port=8010, debug=False)

PYAPP

echo "[5/9b] Writing panel environment..."
ADMIN_PASS_HASH="$(ADMIN_PASS="$ADMIN_PASS" python3 - <<'PY'
from werkzeug.security import generate_password_hash
import os
print(generate_password_hash(os.environ["ADMIN_PASS"]))
PY
)"
SESSION_SECRET="$(openssl rand -hex 32)"
cat > /etc/zivpn-panel/panel.env <<EOF
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS_HASH=${ADMIN_PASS_HASH}
PANEL_HOSTNAME=${PANEL_HOSTNAME}
PANEL_TITLE=${PANEL_TITLE}
SESSION_SECRET=${SESSION_SECRET}
EOF
chmod 600 /etc/zivpn-panel/panel.env

echo "[6/9] Creating virtual environment..."
python3 -m venv /opt/zivpn-panel/venv
/opt/zivpn-panel/venv/bin/pip install --upgrade pip >/dev/null
/opt/zivpn-panel/venv/bin/pip install flask gunicorn werkzeug >/dev/null

cat > /etc/systemd/system/zivpn-panel.service <<'EOF'
[Unit]
Description=Zivpn Admin Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/zivpn-panel
EnvironmentFile=/etc/zivpn-panel/panel.env
ExecStart=/opt/zivpn-panel/venv/bin/gunicorn -w 2 -b 127.0.0.1:8010 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "[7/9] Creating nginx reverse proxy on port 8000..."
cat > /etc/nginx/sites-available/zivpn-panel <<'EOF'
server {
    listen 8000 default_server;
    listen [::]:8000 default_server;

    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8010;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
    }
}
EOF
ln -sf /etc/nginx/sites-available/zivpn-panel /etc/nginx/sites-enabled/zivpn-panel
rm -f /etc/nginx/sites-enabled/default || true
nginx -t

echo "[8/9] Configuring Zivpn service..."
cat > /etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=Zivpn VPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

echo "[9/9] Firewall and services..."
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable zivpn.service zivpn-panel.service nginx
systemctl restart zivpn.service
systemctl restart zivpn-panel.service
systemctl restart nginx

ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 8000/tcp >/dev/null 2>&1 || true
ufw allow 5667/udp >/dev/null 2>&1 || true
ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

DEFAULT_IFACE="$(ip -4 route ls | grep default | grep -Po '(?<=dev )\S+' | head -1 || true)"
if [ -n "$DEFAULT_IFACE" ]; then
  iptables -t nat -C PREROUTING -i "$DEFAULT_IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null \
    || iptables -t nat -A PREROUTING -i "$DEFAULT_IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
fi
netfilter-persistent save >/dev/null 2>&1 || true

cat <<MSG

Install complete.

Panel URL: http://$(hostname -I | awk '{print $1}'):8000
Admin Username: $ADMIN_USER
Hostname: $PANEL_HOSTNAME

Zivpn password list is synced from the panel users.
MSG

#!/usr/bin/env bash
set -euo pipefail

trap 'echo "[ERROR] Line $LINENO failed. Check the message above."; exit 1' ERR

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run this script as root."
    exit 1
  fi
}

log() { echo -e "\n[+] $1"; }

need_root

clear
echo "=== Zivpn UDP + Admin Panel Installer (AMD/Intel/ARM Fixed) ==="

# -----------------------------
# Helper: architecture mapping
# -----------------------------
ARCH="$(uname -m)"
BIN_URL=""
case "$ARCH" in
  x86_64|amd64)
    BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
    ;;
  aarch64|arm64)
    BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64"
    ;;
  armv7l|armv8l)
    BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# -----------------------------
# User inputs
# -----------------------------
read -r -p "Admin Username: " ADMIN_USER
while true; do
  read -r -s -p "Admin Password: " ADMIN_PASS
  echo
  read -r -s -p "Confirm Password: " ADMIN_PASS2
  echo
  if [[ -n "$ADMIN_PASS" && "$ADMIN_PASS" == "$ADMIN_PASS2" ]]; then
    break
  fi
  echo "Password mismatch. Try again."
done

read -r -p "Hostname (example: zi.example.com): " PANEL_HOSTNAME
read -r -p "Panel Title [Zivpn Admin Panel]: " PANEL_TITLE
PANEL_TITLE="${PANEL_TITLE:-Zivpn Admin Panel}"

# -----------------------------
# Base packages
# -----------------------------
log "Updating package lists and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  python3 python3-venv python3-pip \
  nginx curl wget openssl sqlite3 tar gzip \
  ca-certificates iptables

# -----------------------------
# Zivpn install
# -----------------------------
log "Installing Zivpn binary..."
systemctl stop zivpn.service 2>/dev/null || true

curl -L --fail --silent --show-error "$BIN_URL" -o /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

mkdir -p /etc/zivpn

if [[ ! -f /etc/zivpn/config.json ]]; then
  log "Downloading default Zivpn config..."
  curl -L --fail --silent --show-error \
    "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json" \
    -o /etc/zivpn/config.json || true
fi

if [[ ! -s /etc/zivpn/config.json ]]; then
  log "Creating fallback Zivpn config..."
  cat > /etc/zivpn/config.json <<'EOF'
{
  "listen": ":5667",
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  },
  "config": ["zi"]
}
EOF
fi

if [[ ! -f /etc/zivpn/zivpn.key || ! -f /etc/zivpn/zivpn.crt ]]; then
  log "Generating self-signed certificate..."
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=US/ST=California/L=Los Angeles/O=Zivpn/OU=Panel/CN=${PANEL_HOSTNAME}" \
    -keyout /etc/zivpn/zivpn.key \
    -out /etc/zivpn/zivpn.crt
fi

cat > /etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=Zivpn UDP Server
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

systemctl daemon-reload
systemctl enable zivpn.service
systemctl restart zivpn.service || true

# Best-effort UDP port rules (no ufw / no iptables-persistent to avoid package conflicts)
DEFAULT_IFACE="$(ip -4 route ls | awk '/default/ {print $5; exit}')"
if [[ -n "${DEFAULT_IFACE:-}" ]]; then
  iptables -t nat -C PREROUTING -i "$DEFAULT_IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$DEFAULT_IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 || true
fi

# -----------------------------
# Panel install
# -----------------------------
log "Installing panel dependencies..."
mkdir -p /opt/zivpn-panel
mkdir -p /opt/zivpn-panel/backups
mkdir -p /opt/zivpn-panel/uploads
mkdir -p /opt/zivpn-panel/tmp

python3 -m venv /opt/zivpn-panel/venv
/opt/zivpn-panel/venv/bin/pip install --upgrade pip >/dev/null
/opt/zivpn-panel/venv/bin/pip install flask gunicorn >/dev/null

# Store credentials in a root-readable env file
cat > /opt/zivpn-panel/.env <<EOF
ADMIN_USER=$(printf '%q' "$ADMIN_USER" | sed "s/^'//;s/'$//")
ADMIN_PASS=$(printf '%q' "$ADMIN_PASS" | sed "s/^'//;s/'$//")
PANEL_TITLE=$(printf '%q' "$PANEL_TITLE" | sed "s/^'//;s/'$//")
PANEL_HOSTNAME=$(printf '%q' "$PANEL_HOSTNAME" | sed "s/^'//;s/'$//")
EOF

cat > /opt/zivpn-panel/app.py <<'PY'
import datetime as dt
import io
import json
import os
import shutil
import sqlite3
import tarfile
import tempfile
from functools import wraps
from pathlib import Path

from flask import (
    Flask, flash, redirect, render_template_string, request,
    send_file, session, url_for
)

APP_DIR = Path("/opt/zivpn-panel")
DB_PATH = APP_DIR / "panel.db"
UPLOAD_DIR = APP_DIR / "uploads"
BACKUP_DIR = APP_DIR / "backups"
TMP_DIR = APP_DIR / "tmp"

ZIVPN_CONFIG = Path("/etc/zivpn/config.json")
ZIVPN_SERVICE = Path("/etc/systemd/system/zivpn.service")
PANEL_SERVICE = Path("/etc/systemd/system/zpanel.service")
NGINX_SITE = Path("/etc/nginx/sites-available/zivpn-panel")
ENV_FILE = APP_DIR / ".env"

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "zivpn-panel-secret-key")

ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "admin123")
PANEL_TITLE = os.environ.get("PANEL_TITLE", "Zivpn Admin Panel")
PANEL_HOSTNAME = os.environ.get("PANEL_HOSTNAME", "localhost")


def load_env_file():
    if not ENV_FILE.exists():
        return
    for line in ENV_FILE.read_text().splitlines():
        if not line.strip() or line.strip().startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ[k.strip()] = v.strip().strip("'").strip('"')


load_env_file()
ADMIN_USER = os.environ.get("ADMIN_USER", ADMIN_USER)
ADMIN_PASS = os.environ.get("ADMIN_PASS", ADMIN_PASS)
PANEL_TITLE = os.environ.get("PANEL_TITLE", PANEL_TITLE)
PANEL_HOSTNAME = os.environ.get("PANEL_HOSTNAME", PANEL_HOSTNAME)


def conn():
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    APP_DIR.mkdir(parents=True, exist_ok=True)
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)

    with conn() as db:
        db.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password TEXT NOT NULL,
            price REAL NOT NULL DEFAULT 0,
            expired_date TEXT NOT NULL,
            create_date TEXT NOT NULL,
            ip_address TEXT NOT NULL,
            hostname TEXT NOT NULL,
            total_flow REAL NOT NULL DEFAULT 0
        )
        """)
        db.commit()


def get_public_ip():
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        try:
            import subprocess
            out = subprocess.check_output(["hostname", "-I"], text=True).strip().split()
            if out:
                return out[0]
        except Exception:
            pass
    return "0.0.0.0"


def parse_date(s):
    return dt.datetime.strptime(s, "%Y-%m-%d").date()


def today():
    return dt.date.today()


def day_left(expired_date):
    try:
        return max((parse_date(expired_date) - today()).days, 0)
    except Exception:
        return 0


def is_online(expired_date):
    return day_left(expired_date) > 0


def sync_zivpn():
    passwords = []
    with conn() as db:
        rows = db.execute("SELECT password FROM users ORDER BY id ASC").fetchall()
        passwords = [r["password"] for r in rows]

    data = {}
    if ZIVPN_CONFIG.exists():
        try:
            data = json.loads(ZIVPN_CONFIG.read_text())
        except Exception:
            data = {}

    if not isinstance(data, dict):
        data = {}

    # Preserve existing keys, but keep password list in the common places
    data.setdefault("auth", {})
    if not isinstance(data.get("auth"), dict):
        data["auth"] = {}
    data["auth"]["mode"] = "passwords"
    data["auth"]["config"] = passwords
    data["config"] = passwords

    ZIVPN_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    ZIVPN_CONFIG.write_text(json.dumps(data, indent=2))
    os.system("systemctl restart zivpn.service >/dev/null 2>&1 || true")


def stats():
    with conn() as db:
        rows = db.execute("SELECT * FROM users ORDER BY id DESC").fetchall()
    total_users = len(rows)
    online = sum(1 for r in rows if is_online(r["expired_date"]))
    offline = total_users - online
    total_sales = sum(float(r["price"]) for r in rows)
    today_sales = sum(
        float(r["price"]) for r in rows
        if r["create_date"] == today().isoformat()
    )
    return {
        "total_users": total_users,
        "online": online,
        "offline": offline,
        "today_sales": today_sales,
        "total_sales": total_sales,
        "rows": rows,
    }


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return fn(*args, **kwargs)
    return wrapper


def safe_extract_tar(tar: tarfile.TarFile, path: str):
    base = Path(path).resolve()
    for member in tar.getmembers():
        member_path = (base / member.name).resolve()
        if not str(member_path).startswith(str(base)):
            raise RuntimeError("Unsafe path in archive")
    tar.extractall(path)


BASE_HEAD = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{ title }}</title>
<style>
  :root{
    --bg:#07111f;
    --card:#101b30;
    --card2:#15233d;
    --text:#e8f0ff;
    --muted:#8ea3c7;
    --line:rgba(255,255,255,.08);
    --blue:#3aa0ff;
    --green:#19c37d;
    --red:#ff5d5d;
    --gold:#f5b942;
    --accent:#8b5cf6;
  }
  *{box-sizing:border-box}
  body{
    margin:0;
    font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;
    background:radial-gradient(circle at top left,#12213d 0,#07111f 45%,#04080f 100%);
    color:var(--text);
  }
  .wrap{max-width:1400px;margin:0 auto;padding:24px}
  .topbar{
    display:flex;justify-content:space-between;align-items:center;gap:16px;
    padding:18px 20px;background:rgba(16,27,48,.82);backdrop-filter:blur(12px);
    border:1px solid var(--line);border-radius:24px;box-shadow:0 10px 40px rgba(0,0,0,.2);
    position:sticky;top:12px;z-index:10
  }
  .brand{display:flex;align-items:center;gap:14px}
  .logo{
    width:48px;height:48px;border-radius:16px;display:grid;place-items:center;
    background:linear-gradient(135deg,#4f8cff,#8b5cf6);font-size:24px;box-shadow:0 12px 30px rgba(79,140,255,.35)
  }
  h1,h2,h3,p{margin:0}
  .title{font-size:22px;font-weight:800}
  .subtitle{color:var(--muted);font-size:13px;margin-top:4px}
  .pill{padding:10px 14px;border-radius:999px;background:rgba(255,255,255,.06);border:1px solid var(--line);color:var(--muted)}
  .grid{display:grid;gap:16px}
  .stats{grid-template-columns:repeat(5,minmax(0,1fr));margin-top:18px}
  .card{
    background:linear-gradient(180deg,rgba(16,27,48,.9),rgba(13,20,35,.95));
    border:1px solid var(--line);border-radius:24px;padding:18px;box-shadow:0 10px 30px rgba(0,0,0,.16)
  }
  .stat-icon{width:46px;height:46px;border-radius:16px;display:grid;place-items:center;font-size:22px;margin-bottom:12px}
  .stat-value{font-size:32px;font-weight:900;letter-spacing:.3px}
  .stat-label{color:var(--muted);margin-top:6px;font-size:14px}
  .pulse-blue{color:var(--blue);animation:pulse 1.4s infinite}
  .pulse-green{color:var(--green);animation:pulse 1.4s infinite}
  .pulse-red{color:var(--red);animation:pulse 1.4s infinite}
  .pulse-gold{color:var(--gold);animation:pulse 1.6s infinite}
  @keyframes pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.04);opacity:.85}}
  .tabs{display:flex;flex-wrap:wrap;gap:10px;margin-top:18px}
  .tabbtn{
    border:none;cursor:pointer;padding:12px 16px;border-radius:16px;background:rgba(255,255,255,.06);
    color:var(--text);font-weight:700;border:1px solid var(--line)
  }
  .tabbtn.active{background:linear-gradient(135deg,#4f8cff,#8b5cf6);box-shadow:0 10px 24px rgba(79,140,255,.22)}
  .tabcontent{display:none;margin-top:16px}
  .tabcontent.active{display:block}
  .section-title{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}
  .section-title h2{font-size:20px}
  .muted{color:var(--muted)}
  .formgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
  input,select,textarea{
    width:100%;padding:14px 15px;border-radius:16px;border:1px solid var(--line);
    background:#0b1527;color:var(--text);outline:none
  }
  input::placeholder,textarea::placeholder{color:#789}
  .btn{
    display:inline-flex;align-items:center;gap:10px;border:none;cursor:pointer;padding:12px 16px;border-radius:14px;
    font-weight:800;color:white;background:linear-gradient(135deg,#4f8cff,#8b5cf6)
  }
  .btn.green{background:linear-gradient(135deg,#0fb981,#19c37d)}
  .btn.red{background:linear-gradient(135deg,#ff6b6b,#d63d3d)}
  .btn.gray{background:linear-gradient(135deg,#334155,#475569)}
  .btn.small{padding:9px 12px;border-radius:12px;font-size:13px}
  .notice{
    padding:14px 16px;border-radius:16px;background:rgba(79,140,255,.12);border:1px solid rgba(79,140,255,.24);
    margin-bottom:14px
  }
  .users{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
  .usercard{
    background:linear-gradient(180deg,rgba(17,30,56,.95),rgba(11,18,32,.97));
    border:1px solid var(--line);border-radius:22px;padding:16px
  }
  .userhead{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:12px}
  .badge{padding:7px 10px;border-radius:999px;font-size:12px;font-weight:800}
  .online{background:rgba(25,195,125,.14);color:#4ef0b0;border:1px solid rgba(25,195,125,.26)}
  .offline{background:rgba(255,93,93,.14);color:#ff8a8a;border:1px solid rgba(255,93,93,.24)}
  .kv{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px}
  .kv div{padding:10px 12px;border-radius:14px;background:rgba(255,255,255,.04);border:1px solid var(--line)}
  .label{display:block;color:var(--muted);font-size:12px;margin-bottom:4px}
  .value{font-weight:800;word-break:break-word}
  .actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}
  .flash{
    margin:14px 0;padding:14px 16px;border-radius:16px;border:1px solid rgba(25,195,125,.24);
    background:rgba(25,195,125,.12);color:#a9ffd8
  }
  .errorflash{
    margin:14px 0;padding:14px 16px;border-radius:16px;border:1px solid rgba(255,93,93,.24);
    background:rgba(255,93,93,.12);color:#ffc2c2
  }
  .split{display:grid;grid-template-columns:1.2fr .8fr;gap:16px}
  .footer{margin-top:18px;color:var(--muted);font-size:13px;text-align:center}
  a{color:inherit;text-decoration:none}
  .top-actions{display:flex;gap:10px;flex-wrap:wrap}
  .copy-btn{background:rgba(255,255,255,.06);border:1px solid var(--line);color:var(--text)}
  .form-actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:14px}
  .tablelike{display:grid;gap:10px}
  .restorebox{padding:16px;border:1px dashed rgba(255,255,255,.18);border-radius:18px;background:rgba(255,255,255,.03)}
  @media (max-width:1100px){
    .stats,.users,.split,.formgrid{grid-template-columns:1fr}
    .topbar{position:static}
  }
</style>
</head>
<body>
<div class="wrap">
"""

BASE_TAIL = """
</div>
<script>
function openTab(tabId){
  document.querySelectorAll('.tabcontent').forEach(el=>el.classList.remove('active'));
  document.querySelectorAll('.tabbtn').forEach(el=>el.classList.remove('active'));
  document.getElementById(tabId).classList.add('active');
  document.getElementById('btn-' + tabId).classList.add('active');
}
function copyText(text){
  navigator.clipboard.writeText(text).then(()=>{
    alert('Copied');
  }).catch(()=>{
    prompt('Copy this text:', text);
  });
}
window.addEventListener('load', ()=>{
  const first = document.querySelector('.tabcontent');
  const btn = document.querySelector('.tabbtn');
  if(first && btn){ first.classList.add('active'); btn.classList.add('active'); }
});
</script>
</body>
</html>
"""


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        u = request.form.get("username", "")
        p = request.form.get("password", "")
        if u == ADMIN_USER and p == ADMIN_PASS:
            session["logged_in"] = True
            return redirect(url_for("dashboard"))
        flash("Invalid username or password", "error")
    return render_template_string(
        BASE_HEAD + """
        <div class="card" style="max-width:480px;margin:80px auto">
          <div class="section-title">
            <h2>🔐 Admin Login</h2>
            <span class="pill">{{ title }}</span>
          </div>
          {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
              {% for category, message in messages %}
                <div class="{{ 'errorflash' if category == 'error' else 'flash' }}">{{ message }}</div>
              {% endfor %}
            {% endif %}
          {% endwith %}
          <form method="post">
            <div class="grid" style="gap:12px">
              <input name="username" placeholder="Admin Username" autocomplete="username" required>
              <input name="password" type="password" placeholder="Admin Password" autocomplete="current-password" required>
              <button class="btn" type="submit">Sign In</button>
            </div>
          </form>
          <div class="footer">Panel Port 8000</div>
        </div>
        """ + BASE_TAIL,
        title=PANEL_TITLE,
    )


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
def root():
    return redirect(url_for("dashboard"))


@app.route("/dashboard")
@login_required
def dashboard():
    s = stats()
    rows = s["rows"]
    now_ip = get_public_ip()
    notice = None
    if "msg" in request.args:
        notice = request.args.get("msg")
    return render_template_string(
        BASE_HEAD + """
        <div class="topbar">
          <div class="brand">
            <div class="logo">⚡</div>
            <div>
              <div class="title">{{ title }}</div>
              <div class="subtitle">Hostname: {{ hostname }} · Port 8000 · Zivpn Control Panel</div>
            </div>
          </div>
          <div class="top-actions">
            <span class="pill">Server IP: {{ ip }}</span>
            <a class="btn gray small" href="{{ url_for('backup') }}">🗄️ Backup</a>
            <a class="btn gray small" href="{{ url_for('logout') }}">🚪 Logout</a>
          </div>
        </div>

        {% if notice %}
          <div class="notice">{{ notice }}</div>
        {% endif %}

        <div class="grid stats">
          <div class="card">
            <div class="stat-icon" style="background:rgba(58,160,255,.14)">👥</div>
            <div class="stat-value pulse-blue">{{ s.total_users }}</div>
            <div class="stat-label">Total Users</div>
          </div>
          <div class="card">
            <div class="stat-icon" style="background:rgba(25,195,125,.14)">🟢</div>
            <div class="stat-value pulse-green">{{ s.online }}</div>
            <div class="stat-label">Online</div>
          </div>
          <div class="card">
            <div class="stat-icon" style="background:rgba(255,93,93,.14)">🔴</div>
            <div class="stat-value pulse-red">{{ s.offline }}</div>
            <div class="stat-label">Offline</div>
          </div>
          <div class="card">
            <div class="stat-icon" style="background:rgba(245,185,66,.14)">💰</div>
            <div class="stat-value pulse-gold">{{ "%.2f"|format(s.today_sales) }} THB</div>
            <div class="stat-label">Today Sales</div>
          </div>
          <div class="card">
            <div class="stat-icon" style="background:rgba(139,92,246,.14)">🏦</div>
            <div class="stat-value" style="color:#c3b0ff">{{ "%.2f"|format(s.total_sales) }} THB</div>
            <div class="stat-label">Total Sales</div>
          </div>
        </div>

        <div class="tabs">
          <button class="tabbtn" id="btn-summary" onclick="openTab('summary')">📊 Summary</button>
          <button class="tabbtn" id="btn-add" onclick="openTab('add')">➕ Add User</button>
          <button class="tabbtn" id="btn-users" onclick="openTab('users')">🧾 User Cards</button>
          <button class="tabbtn" id="btn-restore" onclick="openTab('restore')">♻️ Backup / Restore</button>
          <button class="tabbtn" id="btn-info" onclick="openTab('info')">ℹ️ Panel Info</button>
        </div>

        <div id="summary" class="tabcontent">
          <div class="split">
            <div class="card">
              <div class="section-title"><h2>📈 Live Summary</h2><span class="pill">Animated stats</span></div>
              <div class="grid stats" style="grid-template-columns:repeat(2,minmax(0,1fr));margin-top:0">
                <div class="card" style="margin:0">
                  <div class="stat-icon" style="background:rgba(58,160,255,.14)">👥</div>
                  <div class="stat-value pulse-blue">{{ s.total_users }}</div>
                  <div class="stat-label">Total Users</div>
                </div>
                <div class="card" style="margin:0">
                  <div class="stat-icon" style="background:rgba(25,195,125,.14)">🟢</div>
                  <div class="stat-value pulse-green">{{ s.online }}</div>
                  <div class="stat-label">Online</div>
                </div>
                <div class="card" style="margin:0">
                  <div class="stat-icon" style="background:rgba(255,93,93,.14)">🔴</div>
                  <div class="stat-value pulse-red">{{ s.offline }}</div>
                  <div class="stat-label">Offline</div>
                </div>
                <div class="card" style="margin:0">
                  <div class="stat-icon" style="background:rgba(245,185,66,.14)">💰</div>
                  <div class="stat-value pulse-gold">{{ "%.2f"|format(s.today_sales) }} THB</div>
                  <div class="stat-label">Today Sales</div>
                </div>
              </div>
            </div>
            <div class="card">
              <div class="section-title"><h2>🛠️ Quick Actions</h2></div>
              <div class="tablelike">
                <div class="notice">Server IP: <b>{{ ip }}</b><br>Hostname: <b>{{ hostname }}</b></div>
                <div class="notice">Zivpn config passwords are synced automatically after Add/Edit/Delete.</div>
                <div class="form-actions">
                  <button class="btn" onclick="openTab('add')">➕ Add User</button>
                  <a class="btn gray" href="{{ url_for('backup') }}">🗄️ Download Backup</a>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div id="add" class="tabcontent">
          <div class="card">
            <div class="section-title">
              <h2>➕ Add User</h2>
              <span class="pill">Generates Zivpn password</span>
            </div>
            <form method="post" action="{{ url_for('add_user') }}">
              <div class="formgrid">
                <input name="username" placeholder="Username" required>
                <input name="password" placeholder="Password" required>
                <input name="price" placeholder="Price (THB)" type="number" step="0.01" min="0" required>
                <input name="expired_date" type="date" required>
                <input name="total_flow" placeholder="Total Flow (GB)" type="number" step="0.01" min="0" value="0">
                <input name="hostname" placeholder="Hostname" value="{{ hostname }}" required>
              </div>
              <div class="form-actions">
                <button class="btn green" type="submit">✅ Add Account</button>
              </div>
            </form>
          </div>
        </div>

        <div id="users" class="tabcontent">
          <div class="section-title">
            <h2>🧾 User Cards</h2>
            <span class="pill">{{ s.total_users }} users</span>
          </div>
          <div class="users">
            {% for u in s.rows %}
            <div class="usercard">
              <div class="userhead">
                <div>
                  <div style="font-size:18px;font-weight:900">{{ u["username"] }}</div>
                  <div class="muted">Password synced to Zivpn</div>
                </div>
                <span class="badge {{ 'online' if u['day_left'] > 0 else 'offline' }}">
                  {{ '🟢 Online' if u['day_left'] > 0 else '🔴 Offline' }}
                </span>
              </div>
              <div class="kv">
                <div><span class="label">IP Address</span><span class="value">{{ u["ip_address"] }}</span></div>
                <div><span class="label">Hostname</span><span class="value">{{ u["hostname"] }}</span></div>
                <div><span class="label">Username</span><span class="value">{{ u["username"] }}</span></div>
                <div><span class="label">Password</span><span class="value">{{ u["password"] }}</span></div>
                <div><span class="label">Create Date</span><span class="value">{{ u["create_date"] }}</span></div>
                <div><span class="label">Expired Date</span><span class="value">{{ u["expired_date"] }}</span></div>
                <div><span class="label">Day Left</span><span class="value">{{ u["day_left"] }} day(s)</span></div>
                <div><span class="label">Total Flow (GB)</span><span class="value">{{ u["total_flow"] }}</span></div>
              </div>
              <div class="actions">
                <button class="btn small copy-btn" onclick="copyText('IP Address: {{ u['ip_address'] }}\\nHostname: {{ u['hostname'] }}\\nUsername: {{ u['username'] }}\\nPassword: {{ u['password'] }}\\nCreate Date: {{ u['create_date'] }}\\nExpired Date: {{ u['expired_date'] }}\\nDay Left: {{ u['day_left'] }}\\nTotal Flow (GB): {{ u['total_flow'] }}')">📋 Copy All</button>
                <button class="btn small copy-btn" onclick="copyText('{{ u['username'] }}')">👤 Username</button>
                <button class="btn small copy-btn" onclick="copyText('{{ u['password'] }}')">🔑 Password</button>
                <a class="btn small gray" href="{{ url_for('edit_user', user_id=u['id']) }}">✏️ Edit</a>
                <form method="post" action="{{ url_for('delete_user', user_id=u['id']) }}" onsubmit="return confirm('Delete this user?');" style="display:inline">
                  <button class="btn small red" type="submit">🗑️ Delete</button>
                </form>
              </div>
            </div>
            {% endfor %}
          </div>
        </div>

        <div id="restore" class="tabcontent">
          <div class="split">
            <div class="card">
              <div class="section-title"><h2>🗄️ Backup</h2><span class="pill">Download .tar.gz</span></div>
              <p class="muted">This backup includes the SQLite database, Zivpn config, service files, nginx config, and panel env file.</p>
              <div class="form-actions" style="margin-top:16px">
                <a class="btn green" href="{{ url_for('backup') }}">⬇️ Download Backup</a>
              </div>
            </div>
            <div class="card">
              <div class="section-title"><h2>♻️ Restore</h2><span class="pill">Upload backup file</span></div>
              <form method="post" action="{{ url_for('restore') }}" enctype="multipart/form-data">
                <div class="restorebox">
                  <input type="file" name="backup_file" accept=".tar.gz,.tgz" required>
                  <div class="form-actions">
                    <button class="btn red" type="submit">Restore & Restart</button>
                  </div>
                </div>
              </form>
            </div>
          </div>
        </div>

        <div id="info" class="tabcontent">
          <div class="card">
            <div class="section-title"><h2>ℹ️ Panel Information</h2></div>
            <div class="kv">
              <div><span class="label">Panel Title</span><span class="value">{{ title }}</span></div>
              <div><span class="label">Panel Hostname</span><span class="value">{{ hostname }}</span></div>
              <div><span class="label">Panel Port</span><span class="value">8000</span></div>
              <div><span class="label">Backend</span><span class="value">Gunicorn + Flask</span></div>
            </div>
            <div class="notice" style="margin-top:14px">
              Zivpn passwords are synced automatically from this panel into /etc/zivpn/config.json.
            </div>
          </div>
        </div>

        <div class="footer">Zivpn Admin Panel · Port 8000 · Server IP {{ ip }}</div>
        """ + BASE_TAIL,
        title=PANEL_TITLE,
        hostname=PANEL_HOSTNAME,
        ip=now_ip,
        s={
            **s,
            "rows": [
                {**dict(r), "day_left": day_left(r["expired_date"])} for r in rows
            ]
        },
        notice=notice,
    )


@app.route("/add", methods=["POST"])
@login_required
def add_user():
    username = request.form.get("username", "").strip()
    password = request.form.get("password", "").strip()
    price = float(request.form.get("price", "0") or 0)
    expired_date = request.form.get("expired_date", "").strip()
    total_flow = float(request.form.get("total_flow", "0") or 0)
    hostname = request.form.get("hostname", "").strip() or PANEL_HOSTNAME

    if not username or not password or not expired_date:
        flash("Username, password, and expired date are required.", "error")
        return redirect(url_for("dashboard"))

    create_date = today().isoformat()
    ip_address = get_public_ip()

    try:
        with conn() as db:
            db.execute(
                """
                INSERT INTO users (username, password, price, expired_date, create_date, ip_address, hostname, total_flow)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (username, password, price, expired_date, create_date, ip_address, hostname, total_flow),
            )
            db.commit()
        sync_zivpn()
        cur = conn().execute("SELECT * FROM users WHERE username = ?", (username,))
        row = cur.fetchone()
        return redirect(url_for("generated", user_id=row["id"]))
    except sqlite3.IntegrityError:
        flash("Username already exists.", "error")
        return redirect(url_for("dashboard"))


@app.route("/generated/<int:user_id>")
@login_required
def generated(user_id):
    with conn() as db:
        row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if not row:
        return redirect(url_for("dashboard"))
    d_left = day_left(row["expired_date"])
    return render_template_string(
        BASE_HEAD + """
        <div class="card" style="max-width:760px;margin:28px auto">
          <div class="section-title">
            <h2>✅ Generate Account Successfully</h2>
            <span class="pill">Zivpn account created</span>
          </div>
          <script>setTimeout(()=>alert('Generate Account Successfully'),200);</script>
          <div class="kv">
            <div><span class="label">IP Address</span><span class="value">{{ row["ip_address"] }}</span><button class="btn small copy-btn" onclick="copyText('{{ row['ip_address'] }}')" style="margin-top:8px">📋 Copy</button></div>
            <div><span class="label">Hostname</span><span class="value">{{ row["hostname"] }}</span><button class="btn small copy-btn" onclick="copyText('{{ row['hostname'] }}')" style="margin-top:8px">📋 Copy</button></div>
            <div><span class="label">Username</span><span class="value">{{ row["username"] }}</span><button class="btn small copy-btn" onclick="copyText('{{ row['username'] }}')" style="margin-top:8px">📋 Copy</button></div>
            <div><span class="label">Password</span><span class="value">{{ row["password"] }}</span><button class="btn small copy-btn" onclick="copyText('{{ row['password'] }}')" style="margin-top:8px">📋 Copy</button></div>
            <div><span class="label">Day Left</span><span class="value">{{ d_left }} day(s)</span></div>
            <div><span class="label">Price</span><span class="value">{{ "%.2f"|format(row["price"]) }} THB</span></div>
          </div>
          <div class="form-actions" style="margin-top:16px">
            <a class="btn" href="{{ url_for('dashboard') }}">⬅️ Back to Dashboard</a>
          </div>
        </div>
        """ + BASE_TAIL,
        title=PANEL_TITLE,
        row=row,
        d_left=d_left,
    )


@app.route("/edit/<int:user_id>", methods=["GET", "POST"])
@login_required
def edit_user(user_id):
    with conn() as db:
        row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if not row:
        return redirect(url_for("dashboard"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()
        price = float(request.form.get("price", "0") or 0)
        expired_date = request.form.get("expired_date", "").strip()
        total_flow = float(request.form.get("total_flow", "0") or 0)

        with conn() as db:
            db.execute("""
                UPDATE users
                SET username = ?, password = ?, price = ?, expired_date = ?, total_flow = ?
                WHERE id = ?
            """, (username, password, price, expired_date, total_flow, user_id))
            db.commit()
        sync_zivpn()
        flash("User updated successfully.", "success")
        return redirect(url_for("dashboard"))

    return render_template_string(
        BASE_HEAD + """
        <div class="card" style="max-width:760px;margin:28px auto">
          <div class="section-title">
            <h2>✏️ Edit User</h2>
            <span class="pill">ID {{ row["id"] }}</span>
          </div>
          <form method="post">
            <div class="formgrid">
              <input name="username" value="{{ row['username'] }}" required>
              <input name="password" value="{{ row['password'] }}" required>
              <input name="price" type="number" step="0.01" min="0" value="{{ row['price'] }}" required>
              <input name="expired_date" type="date" value="{{ row['expired_date'] }}" required>
              <input name="total_flow" type="number" step="0.01" min="0" value="{{ row['total_flow'] }}" required>
              <input value="{{ row['hostname'] }}" disabled>
            </div>
            <div class="form-actions">
              <button class="btn green" type="submit">💾 Save Changes</button>
              <a class="btn gray" href="{{ url_for('dashboard') }}">⬅️ Cancel</a>
            </div>
          </form>
        </div>
        """ + BASE_TAIL,
        title=PANEL_TITLE,
        row=row,
    )


@app.route("/delete/<int:user_id>", methods=["POST"])
@login_required
def delete_user(user_id):
    with conn() as db:
        db.execute("DELETE FROM users WHERE id = ?", (user_id,))
        db.commit()
    sync_zivpn()
    flash("User deleted successfully.", "success")
    return redirect(url_for("dashboard"))


@app.route("/backup")
@login_required
def backup():
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    archive_name = BACKUP_DIR / f"zivpn-panel-backup-{ts}.tar.gz"

    files = [
        DB_PATH,
        ZIVPN_CONFIG,
        ZIVPN_SERVICE,
        PANEL_SERVICE,
        NGINX_SITE,
        ENV_FILE,
    ]

    with tarfile.open(archive_name, "w:gz") as tar:
        for f in files:
            if f.exists():
                tar.add(f, arcname=f.name)

    return send_file(archive_name, as_attachment=True, download_name=archive_name.name)


@app.route("/restore", methods=["POST"])
@login_required
def restore():
    file = request.files.get("backup_file")
    if not file or file.filename == "":
        flash("Please choose a backup file.", "error")
        return redirect(url_for("dashboard"))

    upload_path = UPLOAD_DIR / f"restore-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}.tar.gz"
    file.save(upload_path)

    with tempfile.TemporaryDirectory(dir=TMP_DIR) as td:
        with tarfile.open(upload_path, "r:gz") as tar:
            safe_extract_tar(tar, td)

        for member_name in ["panel.db", "config.json", "zivpn.service", "zpanel.service", "zivpn-panel", ".env"]:
            src = Path(td) / member_name
            if src.exists():
                if member_name == "panel.db":
                    shutil.copy2(src, DB_PATH)
                elif member_name == "config.json":
                    shutil.copy2(src, ZIVPN_CONFIG)
                elif member_name == "zivpn.service":
                    shutil.copy2(src, ZIVPN_SERVICE)
                elif member_name == "zpanel.service":
                    shutil.copy2(src, PANEL_SERVICE)
                elif member_name == ".env":
                    shutil.copy2(src, ENV_FILE)

    os.system("systemctl daemon-reload >/dev/null 2>&1 || true")
    os.system("systemctl restart nginx >/dev/null 2>&1 || true")
    os.system("systemctl restart zivpn.service >/dev/null 2>&1 || true")
    os.system("systemctl restart zpanel.service >/dev/null 2>&1 || true")
    flash("Restore completed successfully.", "success")
    return redirect(url_for("dashboard"))


@app.route("/health")
def health():
    return {"status": "ok"}


init_db()
sync_zivpn()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5001, debug=False)
PY

cat > /etc/systemd/system/zpanel.service <<'EOF'
[Unit]
Description=Zivpn Admin Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/zivpn-panel
EnvironmentFile=/opt/zivpn-panel/.env
ExecStart=/opt/zivpn-panel/venv/bin/gunicorn -w 2 -b 127.0.0.1:5001 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------
# nginx on port 8000
# -----------------------------
log "Configuring nginx on port 8000..."
rm -f /etc/nginx/sites-enabled/default || true

cat > /etc/nginx/sites-available/zivpn-panel <<EOF
server {
    listen 8000;
    server_name ${PANEL_HOSTNAME} _;
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }
}
EOF

ln -sf /etc/nginx/sites-available/zivpn-panel /etc/nginx/sites-enabled/zivpn-panel
nginx -t
systemctl restart nginx

# -----------------------------
# Final services
# -----------------------------
systemctl daemon-reload
systemctl enable zpanel.service
systemctl restart zpanel.service

echo
echo "=============================================="
echo "INSTALL COMPLETE"
echo "Panel URL: http://${PANEL_HOSTNAME}:8000"
echo "Admin Username: ${ADMIN_USER}"
echo "Panel Title: ${PANEL_TITLE}"
echo "Zivpn Service: active if binary/config are valid"
echo "=============================================="
echo "If you use a domain, point it to this VPS IP first."
echo "If UDP still needs public access, open ports 5667 and 6000-19999 in your firewall/provider panel."

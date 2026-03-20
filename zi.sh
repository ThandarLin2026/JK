#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo -e "\n[ERROR] Line $LINENO failed. Check the message above." >&2' ERR

export DEBIAN_FRONTEND=noninteractive

APP_DIR="/opt/zivpn-panel"
DB_FILE="$APP_DIR/panel.db"
SETTINGS_FILE="$APP_DIR/settings.json"
APP_FILE="$APP_DIR/app.py"
SERVICE_FILE="/etc/systemd/system/zpanel.service"
ZIVPN_SERVICE_FILE="/etc/systemd/system/zivpn.service"
ZIVPN_DIR="/etc/zivpn"
ZIVPN_CONFIG="$ZIVPN_DIR/config.json"
ZIVPN_BIN="/usr/local/bin/zivpn"
NGINX_SITE="/etc/nginx/sites-available/zivpn_panel"
NGINX_LINK="/etc/nginx/sites-enabled/zivpn_panel"

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
SERVER_IP="${SERVER_IP:-127.0.0.1}"

echo "=== Zivpn UDP + Admin Panel Installer (Fixed) ==="

read -p "Admin Username: " ADMIN_USER
while true; do
  read -s -p "Admin Password: " ADMIN_PASS
  echo
  read -s -p "Confirm Password: " ADMIN_PASS2
  echo
  if [[ "$ADMIN_PASS" == "$ADMIN_PASS2" && -n "$ADMIN_PASS" ]]; then
    break
  fi
  echo "Passwords do not match or empty. Try again."
done

read -p "Hostname (example: zi.example.com): " HOSTNAME
read -p "Panel Title [Zivpn Admin Panel]: " PANEL_TITLE
PANEL_TITLE="${PANEL_TITLE:-Zivpn Admin Panel}"

if [[ -z "${HOSTNAME:-}" ]]; then
  echo "Hostname cannot be empty."
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    ZIVPN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
    ;;
  aarch64|arm64)
    ZIVPN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64"
    ;;
  armv7l|armv8l)
    ZIVPN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo
echo "[1/9] Repairing packages and installing base dependencies..."
dpkg --configure -a >/dev/null 2>&1 || true
apt-get update -y
apt-get -f install -y || true
apt-get install -y \
  ca-certificates \
  curl \
  wget \
  openssl \
  nginx \
  sqlite3 \
  python3 \
  python3-pip \
  python3-dev \
  build-essential

echo
echo "[2/9] Installing Python packages..."
if ! python3 -c "import flask, gunicorn" >/dev/null 2>&1; then
  pip3 install --upgrade pip >/dev/null 2>&1 || true
  if ! pip3 install flask gunicorn >/dev/null 2>&1; then
    pip3 install --break-system-packages flask gunicorn >/dev/null 2>&1
  fi
fi

echo
echo "[3/9] Downloading Zivpn binary..."
mkdir -p "$ZIVPN_DIR"
systemctl stop zivpn.service >/dev/null 2>&1 || true
wget -qO "$ZIVPN_BIN" "$ZIVPN_URL"
chmod +x "$ZIVPN_BIN"

if [[ ! -s "$ZIVPN_BIN" ]]; then
  echo "Failed to download Zivpn binary."
  exit 1
fi

echo
echo "[4/9] Creating Zivpn config and certs..."
if [[ -f "$ZIVPN_CONFIG" ]]; then
  cp -f "$ZIVPN_CONFIG" "$ZIVPN_CONFIG.bak.$(date +%s)" || true
fi

if ! curl -fsSL "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json" -o "$ZIVPN_CONFIG"; then
  cat > "$ZIVPN_CONFIG" <<'EOF'
{
  "listen": ":5667",
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  }
}
EOF
fi

openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=State/L=City/O=Zivpn/OU=Panel/CN=zivpn" \
  -keyout "$ZIVPN_DIR/zivpn.key" \
  -out "$ZIVPN_DIR/zivpn.crt" >/dev/null 2>&1 || true

cat > "$ZIVPN_SERVICE_FILE" <<EOF
[Unit]
Description=Zivpn UDP Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$ZIVPN_DIR
ExecStart=$ZIVPN_BIN server -c $ZIVPN_CONFIG
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

echo
echo "[5/9] Writing panel settings..."
SECRET_KEY="$(openssl rand -hex 32)"
ADMIN_HASH="$(python3 - <<PY
from werkzeug.security import generate_password_hash
print(generate_password_hash("""$ADMIN_PASS"""))
PY
)"

mkdir -p "$APP_DIR"
cat > "$SETTINGS_FILE" <<EOF
{
  "admin_user": "$(python3 - <<PY
import json
print(json.dumps("""$ADMIN_USER"""))
PY
)",
  "admin_password_hash": "$(python3 - <<PY
import json
print(json.dumps("""$ADMIN_HASH"""))
PY
)",
  "hostname": "$(python3 - <<PY
import json
print(json.dumps("""$HOSTNAME"""))
PY
)",
  "panel_title": "$(python3 - <<PY
import json
print(json.dumps("""$PANEL_TITLE"""))
PY
)",
  "server_ip": "$(python3 - <<PY
import json
print(json.dumps("""$SERVER_IP"""))
PY
)",
  "secret_key": "$(python3 - <<PY
import json
print(json.dumps("""$SECRET_KEY"""))
PY
)"
}
EOF

echo
echo "[6/9] Writing Flask admin panel..."
cat > "$APP_FILE" <<'PY'
from flask import Flask, render_template_string, request, redirect, url_for, session, flash, send_file, abort
from werkzeug.security import check_password_hash
from datetime import datetime, date
import sqlite3
import json
import os
from io import BytesIO

APP_DIR = "/opt/zivpn-panel"
DB_FILE = f"{APP_DIR}/panel.db"
SETTINGS_FILE = f"{APP_DIR}/settings.json"
ZIVPN_CONFIG = "/etc/zivpn/config.json"

app = Flask(__name__)

def load_settings():
    if not os.path.exists(SETTINGS_FILE):
        return {
            "admin_user": "admin",
            "admin_password_hash": "",
            "hostname": "",
            "panel_title": "Zivpn Admin Panel",
            "server_ip": "127.0.0.1",
            "secret_key": "change-me"
        }
    with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
        return json.load(f)

SETTINGS = load_settings()
app.secret_key = SETTINGS.get("secret_key", "change-me")

def conn():
    c = sqlite3.connect(DB_FILE)
    c.row_factory = sqlite3.Row
    return c

def init_db():
    os.makedirs(APP_DIR, exist_ok=True)
    with conn() as db:
        db.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password TEXT NOT NULL,
            price REAL NOT NULL DEFAULT 0,
            expired_date TEXT NOT NULL,
            hostname TEXT NOT NULL DEFAULT '',
            ip_address TEXT NOT NULL DEFAULT '',
            total_flow_gb REAL NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """)
        db.commit()

def today_str():
    return date.today().isoformat()

def parse_date(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except Exception:
        return None

def day_left(expired_date):
    d = parse_date(expired_date)
    if not d:
        return 0
    delta = (d - date.today()).days
    return delta if delta > 0 else 0

def status_for(expired_date):
    d = parse_date(expired_date)
    if not d:
        return "offline"
    return "online" if d >= date.today() else "offline"

def get_users():
    with conn() as db:
        rows = db.execute("SELECT * FROM users ORDER BY id DESC").fetchall()
    return rows

def get_user(uid):
    with conn() as db:
        row = db.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
    return row

def compute_stats(users):
    total = len(users)
    online = sum(1 for u in users if status_for(u["expired_date"]) == "online")
    offline = total - online
    today = today_str()
    today_rows = [u for u in users if u["created_at"][:10] == today]
    today_sales = sum(float(u["price"] or 0) for u in today_rows)
    total_sales = sum(float(u["price"] or 0) for u in users)
    return {
        "total_users": total,
        "online_users": online,
        "offline_users": offline,
        "today_sales": today_sales,
        "total_sales": total_sales,
    }

def sync_zivpn_passwords():
    if not os.path.exists(ZIVPN_CONFIG):
        return
    users = get_users()
    passwords = []
    for u in users:
        p = str(u["password"])
        if p and p not in passwords:
            passwords.append(p)

    try:
        with open(ZIVPN_CONFIG, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        return

    changed = False
    if isinstance(cfg, dict):
        if isinstance(cfg.get("auth"), dict):
            if "config" in cfg["auth"]:
                cfg["auth"]["config"] = passwords
                changed = True
            if "passwords" in cfg["auth"]:
                cfg["auth"]["passwords"] = passwords
                changed = True
        if "config" in cfg and isinstance(cfg.get("config"), list):
            cfg["config"] = passwords
            changed = True
        if "passwords" in cfg and isinstance(cfg.get("passwords"), list):
            cfg["passwords"] = passwords
            changed = True

    if changed:
        with open(ZIVPN_CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)

def require_login():
    if not session.get("logged_in"):
        return redirect(url_for("login"))
    return None

@app.before_request
def guard():
    allowed = {"login", "static"}
    if request.endpoint in allowed or request.endpoint is None:
        return None
    if not session.get("logged_in"):
        return redirect(url_for("login"))
    return None

@app.route("/", methods=["GET", "POST"])
def login():
    settings = load_settings()
    if request.method == "POST":
        u = request.form.get("username", "").strip()
        p = request.form.get("password", "")
        if u == settings.get("admin_user") and check_password_hash(settings.get("admin_password_hash", ""), p):
            session["logged_in"] = True
            flash("Login successful", "success")
            return redirect(url_for("dashboard"))
        flash("Invalid username or password", "danger")

    return render_template_string("""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ settings.panel_title }}</title>
<style>
body{margin:0;font-family:Arial,Helvetica,sans-serif;background:#07111f;color:#fff;display:flex;align-items:center;justify-content:center;min-height:100vh}
.box{width:min(420px,92vw);background:#0e1a2b;border:1px solid #20324e;border-radius:18px;padding:28px;box-shadow:0 14px 40px rgba(0,0,0,.35)}
h1{margin:0 0 6px;font-size:28px}
p{margin:0 0 18px;color:#93a4bf}
input,button{width:100%;box-sizing:border-box;border-radius:12px;border:none;padding:14px 16px;font-size:16px}
input{background:#14233a;color:#fff;margin-bottom:12px;outline:none;border:1px solid #27405e}
button{background:linear-gradient(135deg,#2f7cff,#55c7ff);color:#fff;font-weight:700;cursor:pointer}
.notice{padding:12px 14px;border-radius:12px;margin-bottom:12px;background:#17263c;border:1px solid #27405e;color:#d7e6ff}
.small{margin-top:12px;font-size:13px;color:#8394b0}
</style>
</head>
<body>
<div class="box">
  <h1>{{ settings.panel_title }}</h1>
  <p>Admin login</p>
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% for cat,msg in messages %}
      <div class="notice">{{ msg }}</div>
    {% endfor %}
  {% endwith %}
  <form method="post">
    <input name="username" placeholder="Admin Username" autocomplete="username">
    <input name="password" type="password" placeholder="Admin Password" autocomplete="current-password">
    <button type="submit">Sign in</button>
  </form>
  <div class="small">Hostname: {{ settings.hostname }} • Panel Port: 8000</div>
</div>
</body>
</html>
    """, settings=settings)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/dashboard")
def dashboard():
    settings = load_settings()
    users = get_users()
    stats = compute_stats(users)
    tab = request.args.get("tab", "total")
    q = request.args.get("q", "").strip().lower()

    def matches(u):
        s = status_for(u["expired_date"])
        if tab == "online" and s != "online":
            return False
        if tab == "offline" and s != "offline":
            return False
        if tab == "today_sales" and u["created_at"][:10] != today_str():
            return False
        return True

    filtered = [u for u in users if matches(u)]
    if q:
        filtered = [
            u for u in filtered
            if q in u["username"].lower()
            or q in u["password"].lower()
            or q in str(u["hostname"]).lower()
            or q in str(u["expired_date"]).lower()
        ]

    today_total = sum(float(u["price"] or 0) for u in users if u["created_at"][:10] == today_str())
    total_total = sum(float(u["price"] or 0) for u in users)

    return render_template_string(TEMPLATE,
        settings=settings,
        stats=stats,
        users=filtered,
        today_total=today_total,
        total_total=total_total,
        tab=tab,
        q=q,
        day_left=day_left,
        status_for=status_for
    )

@app.route("/add", methods=["GET", "POST"])
def add_user():
    settings = load_settings()
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()
        price = request.form.get("price", "0").strip() or "0"
        expired_date = request.form.get("expired_date", "").strip()
        hostname = request.form.get("hostname", "").strip() or settings.get("hostname", "")
        total_flow_gb = request.form.get("total_flow_gb", "0").strip() or "0"
        ip_address = settings.get("server_ip", "127.0.0.1")

        if not username or not password or not expired_date:
            flash("Username, Password and Expired Date are required.", "danger")
            return redirect(url_for("dashboard"))

        with conn() as db:
            try:
                db.execute("""
                    INSERT INTO users (username, password, price, expired_date, hostname, ip_address, total_flow_gb, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                """, (username, password, float(price), expired_date, hostname, ip_address, float(total_flow_gb)))
                db.commit()
            except sqlite3.IntegrityError:
                flash("Username already exists.", "danger")
                return redirect(url_for("dashboard"))

        sync_zivpn_passwords()
        try:
            os.system("systemctl restart zivpn.service >/dev/null 2>&1")
        except Exception:
            pass

        flash("Generate Account Successfully", "success")
        return redirect(url_for("dashboard", tab="total"))

    return redirect(url_for("dashboard"))

@app.route("/edit/<int:uid>", methods=["GET", "POST"])
def edit_user(uid):
    settings = load_settings()
    user = get_user(uid)
    if not user:
        abort(404)

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()
        price = request.form.get("price", "0").strip() or "0"
        expired_date = request.form.get("expired_date", "").strip()
        hostname = request.form.get("hostname", "").strip() or settings.get("hostname", "")
        total_flow_gb = request.form.get("total_flow_gb", "0").strip() or "0"
        ip_address = settings.get("server_ip", "127.0.0.1")

        if not username or not password or not expired_date:
            flash("All fields are required.", "danger")
            return redirect(url_for("edit_user", uid=uid))

        with conn() as db:
            try:
                db.execute("""
                    UPDATE users
                    SET username = ?, password = ?, price = ?, expired_date = ?, hostname = ?, ip_address = ?, total_flow_gb = ?, updated_at = datetime('now')
                    WHERE id = ?
                """, (username, password, float(price), expired_date, hostname, ip_address, float(total_flow_gb), uid))
                db.commit()
            except sqlite3.IntegrityError:
                flash("Username already exists.", "danger")
                return redirect(url_for("edit_user", uid=uid))

        sync_zivpn_passwords()
        try:
            os.system("systemctl restart zivpn.service >/dev/null 2>&1")
        except Exception:
            pass
        flash("User updated successfully", "success")
        return redirect(url_for("dashboard"))

    return render_template_string("""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Edit User</title>
<style>
body{font-family:Arial;background:#07111f;color:#fff;margin:0;padding:24px}
.card{max-width:720px;margin:auto;background:#0e1a2b;border:1px solid #20324e;border-radius:18px;padding:24px}
input,button{width:100%;box-sizing:border-box;border-radius:12px;border:none;padding:14px 16px;font-size:16px;margin-bottom:12px}
input{background:#14233a;color:#fff;border:1px solid #27405e}
button{background:linear-gradient(135deg,#2f7cff,#55c7ff);color:#fff;font-weight:700;cursor:pointer}
a{color:#8cc7ff}
</style>
</head>
<body>
<div class="card">
  <h2>Edit User</h2>
  <form method="post">
    <input name="username" value="{{ user.username }}" placeholder="Username">
    <input name="password" value="{{ user.password }}" placeholder="Password">
    <input name="price" value="{{ user.price }}" placeholder="Price THB">
    <input name="hostname" value="{{ user.hostname }}" placeholder="Hostname">
    <input name="total_flow_gb" value="{{ user.total_flow_gb }}" placeholder="Total Flow GB">
    <input type="date" name="expired_date" value="{{ user.expired_date }}">
    <button type="submit">Save</button>
  </form>
  <a href="{{ url_for('dashboard') }}">Back</a>
</div>
</body>
</html>
    """, user=user)

@app.route("/delete/<int:uid>", methods=["POST"])
def delete_user(uid):
    with conn() as db:
        db.execute("DELETE FROM users WHERE id = ?", (uid,))
        db.commit()
    sync_zivpn_passwords()
    try:
        os.system("systemctl restart zivpn.service >/dev/null 2>&1")
    except Exception:
        pass
    flash("User deleted successfully", "success")
    return redirect(url_for("dashboard"))

@app.route("/backup")
def backup():
    payload = {
        "settings": load_settings(),
        "users": [dict(r) for r in get_users()],
        "zivpn_config": None
    }
    try:
        if os.path.exists(ZIVPN_CONFIG):
            with open(ZIVPN_CONFIG, "r", encoding="utf-8") as f:
                payload["zivpn_config"] = json.load(f)
    except Exception:
        payload["zivpn_config"] = None

    bio = BytesIO()
    bio.write(json.dumps(payload, indent=2, ensure_ascii=False).encode("utf-8"))
    bio.seek(0)
    return send_file(
        bio,
        mimetype="application/json",
        as_attachment=True,
        download_name="zivpn_backup.json"
    )

@app.route("/restore", methods=["POST"])
def restore():
    f = request.files.get("backup_file")
    if not f:
        flash("Please choose a backup JSON file.", "danger")
        return redirect(url_for("dashboard"))

    try:
        data = json.load(f.stream)
    except Exception:
        flash("Invalid backup file.", "danger")
        return redirect(url_for("dashboard"))

    if not isinstance(data, dict):
        flash("Backup data is invalid.", "danger")
        return redirect(url_for("dashboard"))

    settings = data.get("settings", {})
    users = data.get("users", [])
    zivpn_cfg = data.get("zivpn_config", None)

    if isinstance(settings, dict) and settings:
        with open(SETTINGS_FILE, "w", encoding="utf-8") as sf:
            json.dump(settings, sf, indent=2)
        app.secret_key = settings.get("secret_key", app.secret_key)

    with conn() as db:
        db.execute("DELETE FROM users")
        for u in users if isinstance(users, list) else []:
            try:
                db.execute("""
                    INSERT INTO users (id, username, password, price, expired_date, hostname, ip_address, total_flow_gb, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    u.get("id"),
                    u.get("username", ""),
                    u.get("password", ""),
                    float(u.get("price", 0) or 0),
                    u.get("expired_date", today_str()),
                    u.get("hostname", ""),
                    u.get("ip_address", ""),
                    float(u.get("total_flow_gb", 0) or 0),
                    u.get("created_at", datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
                    u.get("updated_at", datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
                ))
            except Exception:
                pass
        db.commit()

    if isinstance(zivpn_cfg, dict):
        try:
            with open(ZIVPN_CONFIG, "w", encoding="utf-8") as zf:
                json.dump(zivpn_cfg, zf, indent=2)
        except Exception:
            pass

    sync_zivpn_passwords()
    try:
        os.system("systemctl restart zivpn.service >/dev/null 2>&1")
    except Exception:
        pass

    flash("Restore completed successfully", "success")
    return redirect(url_for("dashboard"))

@app.route("/health")
def health():
    return {"status": "ok"}

TEMPLATE = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ settings.panel_title }}</title>
<style>
:root{
  --bg:#07111f;
  --panel:#0e1a2b;
  --panel2:#13233a;
  --line:#223956;
  --text:#e7f0ff;
  --muted:#90a4bf;
  --blue:#3b82f6;
  --green:#22c55e;
  --red:#ef4444;
  --gold:#f59e0b;
}
*{box-sizing:border-box}
body{margin:0;font-family:Arial,Helvetica,sans-serif;background:linear-gradient(180deg,#06101d 0%,#08131f 100%);color:var(--text)}
a{text-decoration:none;color:inherit}
.wrap{max-width:1400px;margin:0 auto;padding:20px}
.top{
  display:flex;flex-wrap:wrap;gap:14px;align-items:center;justify-content:space-between;
  margin-bottom:18px
}
.brand h1{margin:0;font-size:28px}
.brand .sub{color:var(--muted);margin-top:4px}
.right{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.pill{
  background:rgba(255,255,255,.04);border:1px solid var(--line);
  padding:10px 14px;border-radius:999px;color:#dce9ff;font-size:14px
}
.btn{
  border:none;border-radius:14px;padding:12px 16px;font-weight:700;cursor:pointer;
  display:inline-flex;align-items:center;gap:8px
}
.btn.blue{background:linear-gradient(135deg,#2f7cff,#54c7ff);color:white}
.btn.dark{background:#15263d;color:#fff;border:1px solid var(--line)}
.btn.red{background:linear-gradient(135deg,#ef4444,#f97316);color:white}
.grid{
  display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:14px;margin:18px 0 22px
}
@media (max-width:1200px){.grid{grid-template-columns:repeat(2,minmax(0,1fr));}}
@media (max-width:640px){.grid{grid-template-columns:1fr;}}
.metric{
  background:linear-gradient(180deg,var(--panel),#0c1625);
  border:1px solid var(--line);border-radius:20px;padding:18px;
  box-shadow:0 10px 35px rgba(0,0,0,.25);
  min-height:110px;position:relative;overflow:hidden
}
.metric.active{outline:2px solid rgba(59,130,246,.55)}
.metric .title{color:var(--muted);display:flex;align-items:center;gap:8px;font-size:14px}
.metric .value{font-size:34px;font-weight:800;margin-top:12px;animation:pulse 1.8s infinite}
.metric.blue .value{color:#66a3ff}
.metric.green .value{color:#5df08a}
.metric.red .value{color:#ff7676}
.metric.gold .value{color:#ffcc66}
.metric .small{color:var(--muted);margin-top:8px;font-size:13px}
@keyframes pulse{0%{transform:scale(1)}50%{transform:scale(1.04)}100%{transform:scale(1)}}

.panel{
  background:rgba(14,26,43,.92);
  border:1px solid var(--line);border-radius:22px;padding:18px;margin-bottom:18px
}
.tabs{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px}
.tab{
  padding:12px 16px;border-radius:999px;border:1px solid var(--line);background:#122338;color:#dce9ff;
  font-weight:700;display:inline-flex;align-items:center;gap:8px
}
.tab.active{background:linear-gradient(135deg,#234a86,#1b6d9f);border-color:#4b8fd4}
.controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;margin-bottom:14px}
.search{
  width:min(360px,100%);border-radius:14px;border:1px solid var(--line);background:#122338;color:#fff;
  padding:12px 14px;outline:none
}
.section-title{margin:0 0 14px;font-size:20px}
.notice{padding:12px 14px;border-radius:14px;margin-bottom:10px;border:1px solid var(--line);background:#122338}
.notice.success{border-color:rgba(34,197,94,.45)}
.notice.danger{border-color:rgba(239,68,68,.45)}
.form-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
@media (max-width:900px){.form-grid{grid-template-columns:1fr;}}
.input, .select{
  width:100%;border-radius:12px;border:1px solid var(--line);background:#122338;color:#fff;
  padding:13px 14px;outline:none
}
.form-actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:8px}
.users{
  display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px
}
@media (max-width:1100px){.users{grid-template-columns:1fr;}}
.card{
  border:1px solid var(--line);background:linear-gradient(180deg,#10203a,#0c1727);
  border-radius:20px;padding:16px;box-shadow:0 8px 30px rgba(0,0,0,.24)
}
.card-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:10px}
.badge{padding:7px 10px;border-radius:999px;font-size:12px;font-weight:700}
.badge.online{background:rgba(34,197,94,.14);color:#79ff9e;border:1px solid rgba(34,197,94,.3)}
.badge.offline{background:rgba(239,68,68,.14);color:#ff9a9a;border:1px solid rgba(239,68,68,.3)}
.card h3{margin:0;font-size:18px}
.meta{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:12px}
@media (max-width:640px){.meta{grid-template-columns:1fr;}}
.item{
  background:#0f1c2d;border:1px solid #20324e;border-radius:14px;padding:10px 12px
}
.label{color:var(--muted);font-size:12px;margin-bottom:6px;display:flex;align-items:center;gap:6px}
.value-row{display:flex;justify-content:space-between;gap:10px;align-items:center}
.copy{
  border:none;border-radius:10px;padding:8px 10px;background:#173052;color:#dff0ff;cursor:pointer;font-size:12px
}
.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
.small{font-size:12px;color:var(--muted)}
.hr{height:1px;background:var(--line);margin:16px 0}
.footer{color:var(--muted);margin:20px 0 10px;font-size:13px}
</style>
<script>
function copyText(text){
  navigator.clipboard.writeText(text).then(()=>alert("Copied: " + text));
}
function filterCards(){
  const q = document.getElementById('search').value.toLowerCase();
  document.querySelectorAll('.user-card').forEach(card => {
    const t = card.innerText.toLowerCase();
    card.style.display = t.includes(q) ? '' : 'none';
  });
}
window.addEventListener('load', () => {
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% for cat,msg in messages %}
      alert({{ msg|tojson }});
    {% endfor %}
  {% endwith %}
});
</script>
</head>
<body>
<div class="wrap">
  <div class="top">
    <div class="brand">
      <h1>{{ settings.panel_title }}</h1>
      <div class="sub">Hostname: {{ settings.hostname }} • Server IP: {{ settings.server_ip }} • Port 8000</div>
    </div>
    <div class="right">
      <div class="pill">Admin: {{ settings.admin_user }}</div>
      <a class="btn dark" href="{{ url_for('backup') }}">📦 Backup</a>
      <form action="{{ url_for('restore') }}" method="post" enctype="multipart/form-data" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
        <input class="pill" type="file" name="backup_file" accept=".json,application/json" style="max-width:220px">
        <button class="btn dark" type="submit">♻️ Restore</button>
      </form>
      <a class="btn red" href="{{ url_for('logout') }}">Logout</a>
    </div>
  </div>

  <div class="grid">
    <a class="metric blue {{ 'active' if tab=='total' else '' }}" href="{{ url_for('dashboard', tab='total') }}">
      <div class="title">👥 Total Users</div>
      <div class="value">{{ stats.total_users }}</div>
      <div class="small">All accounts</div>
    </a>

    <a class="metric green {{ 'active' if tab=='online' else '' }}" href="{{ url_for('dashboard', tab='online') }}">
      <div class="title">🟢 Online</div>
      <div class="value">{{ stats.online_users }}</div>
      <div class="small">Active accounts</div>
    </a>

    <a class="metric red {{ 'active' if tab=='offline' else '' }}" href="{{ url_for('dashboard', tab='offline') }}">
      <div class="title">🔴 Offline</div>
      <div class="value">{{ stats.offline_users }}</div>
      <div class="small">Expired accounts</div>
    </a>

    <a class="metric gold {{ 'active' if tab=='today_sales' else '' }}" href="{{ url_for('dashboard', tab='today_sales') }}">
      <div class="title">💰 Today Sales (THB)</div>
      <div class="value">{{ "%.2f"|format(stats.today_sales) }}</div>
      <div class="small">Created today</div>
    </a>

    <a class="metric blue {{ 'active' if tab=='total_sales' else '' }}" href="{{ url_for('dashboard', tab='total_sales') }}">
      <div class="title">📈 Total Sales (THB)</div>
      <div class="value">{{ "%.2f"|format(stats.total_sales) }}</div>
      <div class="small">All time</div>
    </a>
  </div>

  <div class="panel">
    <div class="tabs">
      <a class="tab {{ 'active' if tab=='total' else '' }}" href="{{ url_for('dashboard', tab='total') }}">👥 Total Users</a>
      <a class="tab {{ 'active' if tab=='online' else '' }}" href="{{ url_for('dashboard', tab='online') }}">🟢 Online</a>
      <a class="tab {{ 'active' if tab=='offline' else '' }}" href="{{ url_for('dashboard', tab='offline') }}">🔴 Offline</a>
      <a class="tab {{ 'active' if tab=='today_sales' else '' }}" href="{{ url_for('dashboard', tab='today_sales') }}">💰 Today Sales</a>
      <a class="tab {{ 'active' if tab=='total_sales' else '' }}" href="{{ url_for('dashboard', tab='total_sales') }}">📈 Total Sales</a>
    </div>

    <div class="controls">
      <div>
        <h2 class="section-title">Add User</h2>
        <div class="small">Password is synced to Zivpn automatically.</div>
      </div>
      <input id="search" class="search" onkeyup="filterCards()" placeholder="Search username, password, hostname, date...">
    </div>

    <form action="{{ url_for('add_user') }}" method="post">
      <div class="form-grid">
        <input class="input" name="username" placeholder="Username" required>
        <input class="input" name="password" placeholder="Password" required>
        <input class="input" name="price" placeholder="Price THB" value="0">
        <input class="input" type="date" name="expired_date" required>
        <input class="input" name="hostname" placeholder="Hostname" value="{{ settings.hostname }}" required>
        <input class="input" name="total_flow_gb" placeholder="Total Flow (GB)" value="0">
      </div>
      <div class="form-actions">
        <button class="btn blue" type="submit">➕ Add Account</button>
      </div>
    </form>
  </div>

  <div class="panel">
    <div class="controls">
      <div>
        <h2 class="section-title">Users</h2>
        <div class="small">
          Showing {{ users|length }} record(s)
          {% if tab == 'today_sales' %} • Today Sales: {{ "%.2f"|format(today_total) }} THB{% endif %}
          {% if tab == 'total_sales' %} • Total Sales: {{ "%.2f"|format(total_total) }} THB{% endif %}
        </div>
      </div>
    </div>

    {% if users|length == 0 %}
      <div class="notice">No users found for this tab.</div>
    {% endif %}

    <div class="users">
      {% for u in users %}
      <div class="card user-card">
        <div class="card-head">
          <div>
            <h3>👤 {{ u.username }}</h3>
            <div class="small">Create Date: {{ u.created_at[:10] }} • Expired Date: {{ u.expired_date }} • Day Left: {{ day_left(u.expired_date) }}</div>
          </div>
          <div class="badge {{ status_for(u.expired_date) }}">{{ status_for(u.expired_date)|upper }}</div>
        </div>

        <div class="meta">
          <div class="item">
            <div class="label">🌐 IP Address</div>
            <div class="value-row">
              <div>{{ u.ip_address }}</div>
              <button class="copy" type="button" onclick="copyText('{{ u.ip_address }}')">Copy</button>
            </div>
          </div>

          <div class="item">
            <div class="label">🏷️ Hostname</div>
            <div class="value-row">
              <div>{{ u.hostname }}</div>
              <button class="copy" type="button" onclick="copyText('{{ u.hostname }}')">Copy</button>
            </div>
          </div>

          <div class="item">
            <div class="label">👤 Username</div>
            <div class="value-row">
              <div>{{ u.username }}</div>
              <button class="copy" type="button" onclick="copyText('{{ u.username }}')">Copy</button>
            </div>
          </div>

          <div class="item">
            <div class="label">🔑 Password</div>
            <div class="value-row">
              <div>{{ u.password }}</div>
              <button class="copy" type="button" onclick="copyText('{{ u.password }}')">Copy</button>
            </div>
          </div>

          <div class="item">
            <div class="label">📅 Create Date</div>
            <div>{{ u.created_at[:10] }}</div>
          </div>

          <div class="item">
            <div class="label">⏳ Expired Date</div>
            <div>{{ u.expired_date }}</div>
          </div>

          <div class="item">
            <div class="label">🕒 Day Left</div>
            <div>{{ day_left(u.expired_date) }}</div>
          </div>

          <div class="item">
            <div class="label">📊 Total Flow (GB)</div>
            <div>{{ u.total_flow_gb }}</div>
          </div>
        </div>

        <div class="actions">
          <a class="btn dark" href="{{ url_for('edit_user', uid=u.id) }}">✏️ Edit</a>
          <form method="post" action="{{ url_for('delete_user', uid=u.id) }}" onsubmit="return confirm('Delete this user?')" style="display:inline">
            <button class="btn red" type="submit">🗑️ Delete</button>
          </form>
        </div>
      </div>
      {% endfor %}
    </div>
  </div>

  <div class="footer">
    Zivpn password sync is enabled. Hidden password input is normal; type it and press Enter.
  </div>
</div>
</body>
</html>
"""

if __name__ == "__main__":
    init_db()
    sync_zivpn_passwords()
PY

echo
echo "[7/9] Creating systemd service for panel..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Zivpn Admin Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/usr/local/bin/gunicorn -w 2 -b 127.0.0.1:5000 app:app
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

echo
echo "[8/9] Configuring Nginx on port 8000..."
rm -f /etc/nginx/sites-enabled/default || true
cat > "$NGINX_SITE" <<EOF
server {
    listen 8000;
    server_name $HOSTNAME _;

    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf "$NGINX_SITE" "$NGINX_LINK"
nginx -t
systemctl restart nginx

echo
echo "[9/9] Starting services..."
systemctl daemon-reload
systemctl enable zivpn.service
systemctl enable zpanel.service
systemctl restart zivpn.service
systemctl restart zpanel.service

cat <<EOF

========================================
INSTALL COMPLETE
========================================
Panel URL:  http://$HOSTNAME:8000
Admin User: $ADMIN_USER
Server IP:  $SERVER_IP

Notes:
- Admin password input was hidden while typing. That is normal.
- Zivpn service listens on port 5667.
- Panel data lives in: $APP_DIR
- Backup/Restore is inside the panel.
========================================
EOF

#!/bin/bash
# EC2 Bootstrap — System-level setup for any django-mojo project
#
# Runs BEFORE the repo is cloned. No project files needed.
# Curl one-liner:
#   curl -fsSL https://gist.githubusercontent.com/iamojo/6b422432719106aef8d713fb9a24ed67/raw/ec2_django_mojo_install.sh | sudo bash
#
# With options:
#   TARGET_HOSTNAME=myapp.example.com REMOVE_SSM=y curl -fsSL .../ec2_django_mojo_install.sh | sudo bash
#
# After this runs, clone your repo to /opt/api and run its aws/ec2_deploy.sh

set -euo pipefail

PROJ_PATH="${PROJ_PATH:-/opt/api}"
WEB_ROOT="${WEB_ROOT:-/opt/www}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-}"
REMOVE_SSM="${REMOVE_SSM:-n}"
PYTHON_VER="${PYTHON_VER:-3.12}"
# POSTGRES_VER can be set explicitly (e.g. POSTGRES_VER=17 ... | sudo bash) to pin a
# version. If unset, we auto-detect the newest postgresqlNN-server package available
# in the AL2023 repos at bootstrap time. See detect_latest_postgres_ver() below.
POSTGRES_VER="${POSTGRES_VER:-}"

LOG_FILE="/var/log/ec2-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
trap 'log "ERROR: bootstrap failed at line $LINENO. See $LOG_FILE for full output."' ERR

retry() {
    local n=0 max=3
    until "$@"; do
        n=$((n+1))
        if [[ $n -ge $max ]]; then
            log "Command failed after ${max} attempts: $*"
            return 1
        fi
        log "Retrying: $* (attempt $((n+1))/${max})"
        sleep 3
    done
}

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use: curl -fsSL ... | sudo bash)." >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -q '^ID="\?amzn"\?' /etc/os-release || ! grep -q 'VERSION_ID="\?2023"\?' /etc/os-release; then
    log "ERROR: this script targets Amazon Linux 2023 only. Detected:"
    [[ -f /etc/os-release ]] && cat /etc/os-release | grep -E '^(ID|VERSION_ID)=' || log "  (no /etc/os-release found)"
    exit 1
fi

log "Starting EC2 bootstrap... (logging to $LOG_FILE)"

# ── Optional: set hostname ────────────────────────────────────────────────────
if [[ -n "$TARGET_HOSTNAME" ]]; then
    log "Setting hostname to $TARGET_HOSTNAME..."
    hostnamectl set-hostname "$TARGET_HOSTNAME"
    echo "$TARGET_HOSTNAME" > /etc/hostname
    sed -i "s/127.0.0.1.*/127.0.0.1   localhost $TARGET_HOSTNAME/" /etc/hosts
    if [[ -f /etc/cloud/cloud.cfg ]]; then
        sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi
fi

# ── Fetch bash profile ────────────────────────────────────────────────────────
log "Fetching bash profile..."
retry curl -fsSL https://gist.githubusercontent.com/istarnes/5c38558f57e659a87a8764f9efcf48ae/raw \
    -o /home/ec2-user/.bash_profile
chown ec2-user:ec2-user /home/ec2-user/.bash_profile

# ── System updates (all dnf ops BEFORE changing python alternatives) ──────────
log "Updating system packages..."
dnf update -y

# ── Detect latest available PostgreSQL major version ─────────────────────────
#
# AL2023 has no "postgresql-latest" meta-package — each major version ships as
# its own explicitly-named package (postgresql15, postgresql16, postgresql17,
# postgresql18, ...) added to the repo over time. We scan what dnf can actually
# see and pick the highest number, but this is loudly logged so a version bump
# is never silent. Set POSTGRES_VER explicitly to override/pin.
detect_latest_postgres_ver() {
    dnf list available 2>/dev/null \
        | grep -oE '^postgresql[0-9]+-server\.' \
        | grep -oE '[0-9]+' \
        | sort -n \
        | tail -1
}

if [[ -z "$POSTGRES_VER" ]]; then
    log "Detecting latest available PostgreSQL version..."
    POSTGRES_VER="$(detect_latest_postgres_ver)"
    if [[ -z "$POSTGRES_VER" ]]; then
        log "WARNING: could not detect available PostgreSQL version from dnf — defaulting to 17"
        POSTGRES_VER=17
    else
        log "=========================================================="
        log " Detected PostgreSQL ${POSTGRES_VER} as latest available in AL2023 repos"
        log " (set POSTGRES_VER=NN explicitly to pin a different version)"
        log "=========================================================="
    fi
else
    log "Using explicitly pinned PostgreSQL version: ${POSTGRES_VER}"
fi

log "Installing system packages..."
dnf install -y \
    pcre2-devel systemd-devel \
    iptables ipset \
    cronie rsyslog \
    amazon-cloudwatch-agent \
    "postgresql${POSTGRES_VER}" "postgresql${POSTGRES_VER}-server-devel" \
    git make automake gcc gcc-c++ \
    bzip2 bzip2-devel openssl-devel tcl zlib-devel \
    nginx ImageMagick inotify-tools \
    "python${PYTHON_VER}" "python${PYTHON_VER}-devel"

log "Enabling services..."
systemctl enable --now crond.service
systemctl enable --now rsyslog
systemctl enable --now nginx.service

# ── Optional: remove SSM agent ────────────────────────────────────────────────
if [[ "${REMOVE_SSM}" =~ ^[Yy]$ ]]; then
    log "Removing Amazon SSM agent..."
    pkill -9 -f amazon-ssm-agent || true
    /usr/bin/python3.9 /usr/bin/dnf erase -y amazon-ssm-agent 2>/dev/null || \
        dnf erase -y amazon-ssm-agent 2>/dev/null || true
fi

# ── Users and groups ──────────────────────────────────────────────────────────
#
# Group: www (GID 80)
#   - nginx runs as www
#   - uvicorn (mojo-asgi) runs as www
#   - all shared directories use www as group
#
# Users:
#   ec2-user  — app developer, deploys Django to /opt/api, member of www group
#   deploy    — CI/CD user, deploys static sites to /opt/www, member of www group
#   www       — service user, runs nginx/uvicorn, owns nothing writable
#
# Permissions strategy:
#   Directories: 2775 (rwxrwsr-x) — setgid ensures new files inherit www group
#   Files:       0664 (rw-rw-r--)
#   Owner is the user who writes (ec2-user or deploy), group is always www
#
log "Setting up users and groups..."
chown ec2-user /opt
groupadd -r -g 80 www 2>/dev/null || true
useradd -r -u 80 -g 80 -d /var/www -s /sbin/nologin -M www 2>/dev/null || true
usermod -a -G www ec2-user

# Deploy user for CI/CD
if ! id deploy &>/dev/null; then
    log "Creating deploy user..."
    useradd -m -G www -s /bin/bash deploy
fi

# Generate deploy SSH key (for git clone/pull from GitHub)
if [[ ! -f /home/deploy/.ssh/id_ed25519 ]]; then
    log "Generating deploy SSH key..."
    mkdir -p /home/deploy/.ssh
    ssh-keygen -t ed25519 -C "deploy@$(hostname -f 2>/dev/null || echo ec2)" \
        -f /home/deploy/.ssh/id_ed25519 -N ""
    # Pre-trust GitHub host key so git clone doesn't prompt
    ssh-keyscan -t ed25519 github.com >> /home/deploy/.ssh/known_hosts 2>/dev/null
    chmod 700 /home/deploy/.ssh
    chmod 600 /home/deploy/.ssh/id_ed25519
    chmod 644 /home/deploy/.ssh/id_ed25519.pub /home/deploy/.ssh/known_hosts
    chown -R deploy:deploy /home/deploy/.ssh
fi

# Also give ec2-user GitHub host key for git operations
mkdir -p /home/ec2-user/.ssh
if ! grep -q "github.com" /home/ec2-user/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> /home/ec2-user/.ssh/known_hosts 2>/dev/null
    chown ec2-user:ec2-user /home/ec2-user/.ssh/known_hosts 2>/dev/null || true
fi

# ── /opt/api — Django project ─────────────────────────────────────────────────
log "Creating project directories..."
mkdir -p "${PROJ_PATH}/var/logs" "${PROJ_PATH}/var/pids" "${PROJ_PATH}/var/keys"
chown -R ec2-user:www "${PROJ_PATH}"
chmod 2775 "${PROJ_PATH}"
find "${PROJ_PATH}/var" -type d -exec chmod 2775 {} \;

# ── /opt/www — Static web root ────────────────────────────────────────────────
log "Setting up web root at ${WEB_ROOT}..."
mkdir -p "${WEB_ROOT}"
chown deploy:www "${WEB_ROOT}"
chmod 2775 "${WEB_ROOT}"

# Default error pages
mkdir -p "${WEB_ROOT}/errors"
chown deploy:www "${WEB_ROOT}/errors"
chmod 2775 "${WEB_ROOT}/errors"

cat > "${WEB_ROOT}/errors/404.html" <<'ERRORPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>404 — Not Found</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; align-items: center; justify-content: center;
               min-height: 100vh; background: #f8f9fa; color: #343a40; }
        .container { text-align: center; padding: 2rem; }
        h1 { font-size: 6rem; font-weight: 200; color: #dee2e6; line-height: 1; }
        p { font-size: 1.25rem; margin-top: 1rem; color: #868e96; }
        a { color: #495057; text-decoration: none; border-bottom: 1px solid #ced4da; }
        a:hover { color: #212529; border-color: #495057; }
    </style>
</head>
<body>
    <div class="container">
        <h1>404</h1>
        <p>The page you're looking for doesn't exist.</p>
        <p style="margin-top: 2rem;"><a href="/">Go home</a></p>
    </div>
</body>
</html>
ERRORPAGE

cat > "${WEB_ROOT}/errors/50x.html" <<'ERRORPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Server Error</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; align-items: center; justify-content: center;
               min-height: 100vh; background: #f8f9fa; color: #343a40; }
        .container { text-align: center; padding: 2rem; }
        h1 { font-size: 6rem; font-weight: 200; color: #dee2e6; line-height: 1; }
        p { font-size: 1.25rem; margin-top: 1rem; color: #868e96; }
    </style>
</head>
<body>
    <div class="container">
        <h1>500</h1>
        <p>Something went wrong. We're working on it.</p>
    </div>
</body>
</html>
ERRORPAGE

cat > "${WEB_ROOT}/errors/maintenance.html" <<'ERRORPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Maintenance</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; align-items: center; justify-content: center;
               min-height: 100vh; background: #f8f9fa; color: #343a40; }
        .container { text-align: center; padding: 2rem; }
        h1 { font-size: 3rem; font-weight: 300; color: #495057; }
        p { font-size: 1.25rem; margin-top: 1rem; color: #868e96; }
    </style>
</head>
<body>
    <div class="container">
        <h1>We'll be right back</h1>
        <p>We're performing scheduled maintenance. Please check back shortly.</p>
    </div>
</body>
</html>
ERRORPAGE

# Default index
cat > "${WEB_ROOT}/index.html" <<'INDEXPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Welcome</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; align-items: center; justify-content: center;
               min-height: 100vh; background: #1a1a2e; color: #e0e0e0; }
        .container { text-align: center; }
        h1 { font-size: 2.5rem; font-weight: 300; letter-spacing: 0.05em; }
        p { margin-top: 0.75rem; color: #888; font-size: 1rem; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hello, world.</h1>
        <p>Replace this with your site.</p>
    </div>
</body>
</html>
INDEXPAGE

chown -R deploy:www "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 2775 {} \;
find "${WEB_ROOT}" -type f -exec chmod 0664 {} \;

# Certbot webroot
mkdir -p /var/www/certbot
chown www:www /var/www/certbot

# ── Python setup (AFTER all dnf operations) ───────────────────────────────────
#
# AL2023 system tools (dnf, AWS CLI, and potentially others) shebang on
# /usr/bin/python3, sometimes with whitespace after #! and interpreter flags,
# and depend on that resolving to the real system Python 3.9. Pin those scripts
# before remapping /usr/bin/python3 to the application interpreter, preserving
# flags such as AWS CLI's `-s`.
log "Pinning OS python3 scripts to python3.9 before remapping /usr/bin/python3..."
while IFS= read -r -d '' f; do
    sed -i '1s|^#![[:space:]]*/usr/bin/python3\([[:space:]].*\)\?$|#!/usr/bin/python3.9\1|' "$f"
    log "  pinned shebang: $f"
done < <(grep -rlZ --binary-files=without-match -E '^#![[:space:]]*/usr/bin/python3([[:space:]]|$)' /usr/bin /usr/sbin /usr/libexec 2>/dev/null)

log "Configuring Python ${PYTHON_VER}..."
alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_VER}" 20
alternatives --install /usr/bin/python  python  "/usr/bin/python${PYTHON_VER}" 20

log "Installing pip..."
retry bash -c "curl -fsSL https://bootstrap.pypa.io/get-pip.py | python${PYTHON_VER}"

# Base Python packages (project-specific deps go in ec2_deploy.sh)
# django-mojo pulls in the correct Django version itself — don't pin django separately.
log "Installing base Python packages..."
pip install \
    "psycopg[binary]" \
    "uvicorn[standard]" \
    django-mojo

# ── Certbot, in its own venv ──────────────────────────────────────────────────
# certbot shares NOTHING with the application: co-installed, any project pin
# lands in the same interpreter, and a newer cryptography is enough to break
# certbot's pyOpenSSL — after which `renew --quiet` fails silently until the
# certificate expires. Separate venv, separate dependency graph.
#
# --without-pip plus the same get-pip pattern used for the system pip above:
# AL2023 splits ensurepip's bundled wheels into their own RPM that the dnf
# list doesn't install, and a venv failure here would abort the whole
# bootstrap under `set -euo pipefail`. This way the distro's ensurepip
# packaging doesn't matter.
log "Installing certbot in its own venv (/opt/certbot)..."
python${PYTHON_VER} -m venv --without-pip /opt/certbot
retry bash -c "curl -fsSL https://bootstrap.pypa.io/get-pip.py | /opt/certbot/bin/python"
/opt/certbot/bin/pip install certbot certbot-nginx
ln -snf /opt/certbot/bin/certbot /usr/local/bin/certbot

ln -snf /usr/local/bin/certbot /usr/bin/certbot

# ── Cron jobs ─────────────────────────────────────────────────────────────────
log "Installing cron jobs..."
# PATH matches the project crons (3_mojo_jobs) — /usr/local/bin is where
# certbot's venv symlink lives. Consistency and one less crutch: the
# /usr/bin/certbot symlink above already makes certbot resolvable here.
#
# Plain renew, and --quiet, because bootstrap runs BEFORE the repo is cloned
# and cannot redirect into /opt/api/var/logs. aws/ec2_deploy.sh overwrites
# this cron with the same renew pointed at var/logs/certbot.log, so a node
# with a checkout logs its renewals instead of running them silently.
cat > /etc/cron.d/1_certbot <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * 0 root certbot renew --post-hook "systemctl reload nginx" --quiet
EOF

cat > /etc/cron.d/2_mojo_cron <<EOF
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
* * * * * www ${PROJ_PATH}/bin/cron.py --run 2>/dev/null
EOF

# ── SSH hardening ─────────────────────────────────────────────────────────────
log "Hardening SSH..."
SSHD_CONF="/etc/ssh/sshd_config"
if grep -q "^PasswordAuthentication" "$SSHD_CONF"; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
else
    echo "PasswordAuthentication no" >> "$SSHD_CONF"
fi
if grep -q "^PermitRootLogin" "$SSHD_CONF"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONF"
else
    echo "PermitRootLogin no" >> "$SSHD_CONF"
fi
if sshd -t; then
    systemctl restart sshd
else
    log "ERROR: sshd_config failed validation — NOT restarting sshd. Fix /etc/ssh/sshd_config manually before restarting."
fi

log ""
log "Bootstrap complete."
log ""
log "PostgreSQL version installed: ${POSTGRES_VER}"
log ""
log "Users created:"
log "  ec2-user  — Django app developer (member of www group)"
log "  deploy    — Static site CI/CD (member of www group)"
log "  www       — Service user (nginx, uvicorn)"
log ""
log "Directories:"
log "  ${PROJ_PATH}     — Django project (ec2-user:www, setgid)"
log "  ${WEB_ROOT}      — Static web root (deploy:www, setgid)"
log ""
log "Deploy SSH public key (add to GitHub repo as deploy key):"
log "────────────────────────────────────────────────────────"
cat /home/deploy/.ssh/id_ed25519.pub 2>/dev/null || log "  (not generated)"
log "────────────────────────────────────────────────────────"
log ""
log "Next: clone your repo to ${PROJ_PATH} and run:"
log "  sudo bash ${PROJ_PATH}/aws/ec2_deploy.sh"

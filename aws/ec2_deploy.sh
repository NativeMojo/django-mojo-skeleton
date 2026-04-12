#!/bin/bash
# EC2 Deploy — Project-specific setup (runs AFTER ec2_bootstrap.sh + git clone)
#
# Usage:
#   cd /opt/api && sudo bash aws/ec2_deploy.sh
#
# Customize this file for your project's specific needs:
#   - Add project-specific pip packages
#   - Add custom systemd services
#   - Add project cron jobs

set -euo pipefail

PROJ_PATH="${PROJ_PATH:-/opt/api}"
cd "$PROJ_PATH"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Starting project deploy..."

# Verify bootstrap ran
if ! id www &>/dev/null; then
    log "ERROR: www user not found. Run ec2_bootstrap.sh first."
    exit 1
fi

# ── Project-specific Python packages ─────────────────────────────────────────
# Add your project's extra pip packages here
log "Installing project Python packages..."
pip install \
    python-magic \
    pillow \
    boto3 \
    pyobjict \
    requests \
    ujson \
    pyjwt \
    pycryptodome \
    redis \
    pytz \
    gevent \
    mistune \
    pygments \
    django-redis-cache

# ── Virtualenv ───────────────────────────────────────────────────────────────
if [[ ! -d "${PROJ_PATH}/.venv" ]]; then
    log "Creating virtualenv..."
    python3 -m venv "${PROJ_PATH}/.venv"
fi

log "Installing project deps into venv..."
"${PROJ_PATH}/.venv/bin/pip" install --upgrade pip
"${PROJ_PATH}/.venv/bin/pip" install \
    django-nativemojo "psycopg[binary]" "uvicorn[standard]" \
    redis boto3 pyobjict requests ujson pyjwt pycryptodome \
    gevent mistune pygments django-redis-cache python-magic \
    pillow pytz 2>&1 | tail -5

# ── Nginx configuration ──────────────────────────────────────────────────────
log "Installing nginx configs..."

REPO_NGINX="${PROJ_PATH}/aws/nginx"
if [[ -d "$REPO_NGINX" ]]; then
    cp -f "$REPO_NGINX/nginx.conf" /etc/nginx/nginx.conf
    cp -f "$REPO_NGINX/asgi.inc" /etc/nginx/asgi.inc
    cp -f "$REPO_NGINX/django.inc" /etc/nginx/django.inc

    mkdir -p /etc/nginx/sec.d
    cp -f "$REPO_NGINX/sec.d/"* /etc/nginx/sec.d/

    # Copy domain config (certbot --nginx will update TLS paths)
    cp -f "$REPO_NGINX/conf.d/"*.conf /etc/nginx/conf.d/ 2>/dev/null || true
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log "Nginx configs installed and reloaded."
    else
        log "WARN: nginx config test failed. Check manually: nginx -t"
    fi
fi

# ── Systemd services ─────────────────────────────────────────────────────────
log "Installing systemd services..."

REPO_SYSTEMD="${PROJ_PATH}/aws/nginx/systemd"
if [[ -d "$REPO_SYSTEMD" ]]; then
    cp -f "$REPO_SYSTEMD/"*.service /etc/systemd/system/
    systemctl daemon-reload
    log "Systemd services installed (enable after configuring var/django.conf)."
fi

# ── Project cron jobs ───────────────────────────────────��────────────────────
log "Installing project cron jobs..."

cat > /etc/cron.d/3_mojo_jobs <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * ec2-user ${PROJ_PATH}/bin/jobman start >> ${PROJ_PATH}/var/logs/jobman.log 2>&1
EOF

# ── Var directories ───────────────────────────────────────────────────────────
# ec2-user owns (writes logs, pids, config), www group reads (uvicorn/nginx)
# setgid (2xxx) ensures new files/dirs inherit the www group
log "Setting var directory ownership..."
mkdir -p "${PROJ_PATH}/var/logs" "${PROJ_PATH}/var/pids" "${PROJ_PATH}/var/keys"
chown -R ec2-user:www "${PROJ_PATH}/var"
find "${PROJ_PATH}/var" -type d -exec chmod 2775 {} \;
find "${PROJ_PATH}/var" -type f -exec chmod 0664 {} \;

log ""
log "Project deploy complete."
log ""
log "Remaining steps:"
log "  1. echo 'prod' > ${PROJ_PATH}/var/profile"
log "  2. Edit ${PROJ_PATH}/var/django.conf with DB/cache/AWS credentials"
log "  3. ${PROJ_PATH}/.venv/bin/python ${PROJ_PATH}/bin/manage.py migrate"
log "  4. sudo certbot --nginx -d yourdomain.com"
log "  5. sudo systemctl enable --now mojo-asgi"

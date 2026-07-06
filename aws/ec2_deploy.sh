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

# ── Project Python packages ───────────────────────────────────────────────────
# django-mojo (installed by ec2_bootstrap.sh) already pulls in everything a
# typical django-mojo project needs — psycopg, uvicorn, boto3, redis, pillow,
# etc. — as its own dependencies, so there's nothing to add here by default.
# No venv, by design: these instances run exactly one app, so there's nothing
# for a venv to isolate from — install any genuine project-specific extras
# straight into system python3.12 (ec2_bootstrap.sh already isolates OS
# tooling on its own pinned python3.9, so this is safe).
#
# Add your project's extra pip packages here, e.g.:
#   pip install some-project-specific-package

# ── Self-signed placeholder cert ─────────────────────────────────────────────
# nginx refuses to start with a `listen ... ssl` block that has no
# ssl_certificate — and certbot's --nginx plugin refuses to run against a
# config nginx can't already parse. A snakeoil cert breaks that chicken-and-egg:
# nginx starts fine on a fresh node, then `certbot --nginx -d yourdomain.com`
# replaces these paths with the real cert. Skipped once a real cert exists.
if [[ ! -f /etc/nginx/ssl/snakeoil.crt ]]; then
    log "Generating self-signed placeholder cert..."
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/snakeoil.key \
        -out /etc/nginx/ssl/snakeoil.crt \
        -subj "/CN=localhost" 2>/dev/null
fi

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

# No-op on single-node deploys (aws/certbot_sync.py exits quietly if
# var/ops.json is missing or AWS_CERT_BUCKET/LOAD_BALANCER_DOMAIN/
# PRIMARY_BALANCER_HOST aren't set in it). Needs root: reads privkey.pem
# (600) and reloads nginx.
cat > /etc/cron.d/4_certbot_sync <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root python3 ${PROJ_PATH}/aws/certbot_sync.py >> ${PROJ_PATH}/var/logs/certbot_sync.log 2>&1
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
log "  3. python3 ${PROJ_PATH}/bin/manage.py migrate"
PRIMARY_HOST=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('PRIMARY_BALANCER_HOST',''))" \
    "${PROJ_PATH}/var/ops.json" 2>/dev/null || true)
if [[ -n "$PRIMARY_HOST" ]]; then
    if [[ "$(hostname)" == "$PRIMARY_HOST" ]]; then
        log "  4. sudo certbot --nginx -d yourdomain.com   (this IS the primary node — run certbot here)"
    else
        log "  4. Do NOT run certbot on this node — it's not PRIMARY_BALANCER_HOST ($PRIMARY_HOST)."
        log "     aws/certbot_sync.py (cron, every 5 min) will pull the cert from S3 once the primary issues it."
    fi
else
    log "  4. sudo certbot --nginx -d yourdomain.com"
fi
log "  5. sudo systemctl enable --now mojo-asgi"

#!/bin/bash
# Post-pull deployment — run after every git pull on EC2
#
# Usage: cd /opt/api && sudo bash aws/post_pull.sh

set -euo pipefail

PROJ_PATH="${PROJ_PATH:-/opt/api}"
cd "$PROJ_PATH"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Upgrading django-nativemojo..."
pip install --upgrade django-nativemojo 2>/dev/null || true

log "Installing project dependencies..."
pip install -r requirements.txt 2>/dev/null || true

if [[ -f "${PROJ_PATH}/var/allow_migrate" ]]; then
    log "Running migrations..."
    "${PROJ_PATH}/.venv/bin/python" "${PROJ_PATH}/bin/manage.py" migrate --noinput 2>&1 || \
        python3 "${PROJ_PATH}/bin/manage.py" migrate --noinput 2>&1 || true
fi

log "Collecting static files..."
"${PROJ_PATH}/.venv/bin/python" "${PROJ_PATH}/bin/manage.py" collectstatic --noinput 2>&1 || true

log "Updating nginx configs..."
cp -f "${PROJ_PATH}/aws/nginx/nginx.conf" /etc/nginx/nginx.conf 2>/dev/null || true
cp -f "${PROJ_PATH}/aws/nginx/asgi.inc" /etc/nginx/asgi.inc 2>/dev/null || true
cp -f "${PROJ_PATH}/aws/nginx/django.inc" /etc/nginx/django.inc 2>/dev/null || true
cp -f "${PROJ_PATH}/aws/nginx/sec.d/"* /etc/nginx/sec.d/ 2>/dev/null || true
nginx -t && systemctl reload nginx || log "WARN: nginx config test failed"

log "Updating systemd services..."
cp -f "${PROJ_PATH}/aws/nginx/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload

log "Restarting services..."
systemctl restart mojo-asgi 2>/dev/null || log "WARN: mojo-asgi not running"

log "Post-pull complete."

#!/bin/bash
# Post-pull deployment — run after every git pull on EC2
#
# Usage: cd /opt/api && sudo bash aws/post_deploy.sh
#
# THIS SCRIPT FAILS LOUDLY ON PURPOSE. It previously ended almost every command
# in `|| true` with stderr sent to /dev/null, which defeated the `set -e` on the
# line below and meant a failed dependency install or a failed migration was
# reported as a successful deploy — and then the app was restarted anyway,
# against the wrong schema or with packages missing. A deploy that half-worked
# and said nothing is worse than one that stops.
#
# If you are tempted to add `|| true` to something here, the question to answer
# first is: what should happen if this step fails? "Carry on silently" is almost
# never the answer.

set -euo pipefail

PROJ_PATH="${PROJ_PATH:-/opt/api}"
cd "$PROJ_PATH"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] FATAL: $*" >&2; exit 1; }

# Copy a file that is expected to exist. A missing source is a real problem
# (someone renamed or deleted it) and should be visible, not shrugged off.
install_file() {
    local src="$1" dest="$2"
    [[ -f "$src" ]] || die "expected file is missing: $src"
    cp -f "$src" "$dest"
}

# ── dependencies ─────────────────────────────────────────────────────────────
#
# django-mojo is deliberately UNPINNED and upgraded on every deploy: pinning
# went stale here before and security releases were missed. That policy only
# works if a failed upgrade is loud — a node that cannot reach PyPI silently
# keeping an old framework is the exact outcome the policy exists to prevent.

log "Upgrading django-mojo..."
pip install --upgrade django-mojo \
    || die "django-mojo upgrade failed — refusing to deploy on an unknown framework version"

log "Installing project dependencies..."
pip install -r requirements.txt \
    || die "dependency install failed — refusing to restart with an incomplete environment"

# ── migrations ───────────────────────────────────────────────────────────────
#
# NOTE: var/allow_migrate is a per-box flag file, which cannot serialise
# anything — two boxes that both have it will migrate concurrently, and Django's
# migrate is not concurrency-safe. It is kept for now because removing it
# without a real lock would make that worse, not better. The replacement is a
# Postgres advisory lock held for the migration phase; see the multi-node
# deployment plan, §3.7.

if [[ -f "${PROJ_PATH}/var/allow_migrate" ]]; then
    log "Running migrations..."
    python3 "${PROJ_PATH}/bin/manage.py" migrate --noinput \
        || die "migration failed — the schema is in an unknown state, NOT restarting the app"
else
    log "Skipping migrations (var/allow_migrate absent on this box)."
fi

log "Collecting static files..."
python3 "${PROJ_PATH}/bin/manage.py" collectstatic --noinput \
    || die "collectstatic failed"

# ── nginx ────────────────────────────────────────────────────────────────────

log "Updating nginx configs..."
install_file "${PROJ_PATH}/aws/nginx/nginx.conf"  /etc/nginx/nginx.conf
install_file "${PROJ_PATH}/aws/nginx/asgi.inc"    /etc/nginx/asgi.inc
install_file "${PROJ_PATH}/aws/nginx/django.inc"  /etc/nginx/django.inc

if compgen -G "${PROJ_PATH}/aws/nginx/sec.d/*.conf" > /dev/null; then
    mkdir -p /etc/nginx/sec.d
    cp -f "${PROJ_PATH}/aws/nginx/sec.d/"*.conf /etc/nginx/sec.d/
fi

# Gate the reload on the config test, and treat a failed test as fatal. nginx
# keeps serving the old config either way, but continuing the deploy would
# restart the app behind a web server running configuration that no longer
# matches the code that was just installed.
nginx -t || die "nginx config test failed — not reloading, and not restarting the app"
systemctl reload nginx

# ── systemd ──────────────────────────────────────────────────────────────────
#
# Timers as well as services. Copying only *.service is why config-sync.timer
# was never installed on any box despite the unit existing in the repo.

log "Updating systemd units..."
UNIT_SRC="${PROJ_PATH}/aws/nginx/systemd"
if compgen -G "${UNIT_SRC}/*.service" > /dev/null; then
    cp -f "${UNIT_SRC}/"*.service /etc/systemd/system/
fi
if compgen -G "${UNIT_SRC}/*.timer" > /dev/null; then
    cp -f "${UNIT_SRC}/"*.timer /etc/systemd/system/
fi
systemctl daemon-reload

# Enable any timer we ship. Enabling is idempotent, and a timer that is present
# but never enabled does nothing while looking installed — which is precisely
# how config-sync went unnoticed.
for unit in "${UNIT_SRC}/"*.timer; do
    [[ -e "$unit" ]] || continue
    name="$(basename "$unit")"
    systemctl enable --now "$name" || die "could not enable $name"
    log "  enabled $name"
done

# ── restart ──────────────────────────────────────────────────────────────────

log "Restarting mojo-asgi..."
systemctl restart mojo-asgi || die "mojo-asgi failed to restart"

# A restart that returns 0 only means systemd accepted the unit. Confirm the app
# is actually answering before calling the deploy done.
for _ in $(seq 1 15); do
    if curl -fsS -o /dev/null --max-time 2 http://127.0.0.1/api/version 2>/dev/null; then
        log "Post-deploy complete — app responding."
        exit 0
    fi
    sleep 2
done
die "app did not answer /api/version within 30s of restart"

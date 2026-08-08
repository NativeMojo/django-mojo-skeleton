#!/bin/bash
# Post-checkout deployment — run by aws/update.sh after every code change.
#
# Usage: sudo bash aws/post_deploy.sh [--framework <version>] [--migrate]
#
#   --framework <v>  install django-mojo==<v> (the fleet deploy's pinned
#                    version — pinned across nodes, never across time)
#   --migrate        run `manage.py migrate_locked --noinput` (the canary run)
#   (bare)           legacy behavior: latest django-mojo, no migration.
#                    BARE MUST STAY VALID — the fleet cutover's final legacy
#                    broadcast executes the OLD update.sh, which invokes this
#                    NEW file with no arguments.
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
# Test seams: prod-identical defaults, overridable only by the shell harness.
NGINX_ETC="${NGINX_ETC:-/etc/nginx}"
SYSTEMD_ETC="${SYSTEMD_ETC:-/etc/systemd/system}"
cd "$PROJ_PATH"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] FATAL: $*" >&2; exit 1; }

FRAMEWORK=""
MIGRATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --framework) FRAMEWORK="${2:-}"; shift 2 || die "--framework needs a value" ;;
        --migrate)   MIGRATE=1; shift ;;
        *)           die "unknown argument: $1" ;;
    esac
done

# Copy a file that is expected to exist. A missing source is a real problem
# (someone renamed or deleted it) and should be visible, not shrugged off.
install_file() {
    local src="$1" dest="$2"
    [[ -f "$src" ]] || die "expected file is missing: $src"
    cp -f "$src" "$dest"
}

# ── dependencies ─────────────────────────────────────────────────────────────
#
# Fleet deploys pass --framework: the orchestrator resolves the newest
# django-mojo ONCE per deploy and every node installs exactly that — pinned
# across nodes for the seconds a deploy takes, never across time. Bare runs
# keep the legacy behavior: latest, so security releases are never missed.
# Either way a failure is loud — a node silently keeping an old framework is
# the outcome both policies exist to prevent.

if [ -n "$FRAMEWORK" ]; then
    log "Installing django-mojo==${FRAMEWORK} (fleet-pinned)..."
    pip install "django-mojo==${FRAMEWORK}" \
        || die "django-mojo ${FRAMEWORK} install failed — refusing to deploy on an unknown framework version"
else
    log "Upgrading django-mojo (latest)..."
    pip install --upgrade django-mojo \
        || die "django-mojo upgrade failed — refusing to deploy on an unknown framework version"
fi

log "Installing project dependencies..."
pip install -r requirements.txt \
    || die "dependency install failed — refusing to restart with an incomplete environment"

# ── migrations ───────────────────────────────────────────────────────────────
#
# Migrations run ONLY when the deploy says so (--migrate — the canary run),
# under the real Postgres advisory lock inside migrate_locked. The old
# var/allow_migrate flag file is gone: a per-box flag cannot serialise
# anything, and the advisory lock is the serialisation it was a placeholder
# for — a concurrent migrate exits non-zero instead of racing.

if [ "$MIGRATE" = "1" ]; then
    log "Running migrations (locked)..."
    python3 "${PROJ_PATH}/bin/manage.py" migrate_locked --noinput \
        || die "migration failed — the schema is in an unknown state, NOT restarting the app"
else
    log "Skipping migrations (deploy did not request them)."
fi

log "Collecting static files..."
python3 "${PROJ_PATH}/bin/manage.py" collectstatic --noinput \
    || die "collectstatic failed"

# ── nginx ────────────────────────────────────────────────────────────────────

log "Updating nginx configs..."
install_file "${PROJ_PATH}/aws/nginx/nginx.conf"  "${NGINX_ETC}/nginx.conf"
install_file "${PROJ_PATH}/aws/nginx/asgi.inc"    "${NGINX_ETC}/asgi.inc"
install_file "${PROJ_PATH}/aws/nginx/django.inc"  "${NGINX_ETC}/django.inc"

if compgen -G "${PROJ_PATH}/aws/nginx/sec.d/*.conf" > /dev/null; then
    mkdir -p "${NGINX_ETC}/sec.d"
    cp -f "${PROJ_PATH}/aws/nginx/sec.d/"*.conf "${NGINX_ETC}/sec.d/"
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
    cp -f "${UNIT_SRC}/"*.service "${SYSTEMD_ETC}/"
fi
if compgen -G "${UNIT_SRC}/*.timer" > /dev/null; then
    cp -f "${UNIT_SRC}/"*.timer "${SYSTEMD_ETC}/"
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

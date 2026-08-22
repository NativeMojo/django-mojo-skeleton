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

# ── Edge plane prerequisites ─────────────────────────────────────────────────
# The dnsman/edge certificate + vhost plane installs generations under
# var/edge and needs two root commands it cannot have as the app user. Both
# land here, at provisioning time, so enabling the plane later is a settings
# edit rather than a second manual pass over every node. Both are inert until
# EDGE_CONVERGE_ENABLED is turned on: conf.d/mojo.conf globs a directory that
# does not exist yet (a no-match glob is not an nginx error), and nothing
# invokes sudo until the installer runs.
log "Installing edge plane prerequisites..."

# visudo -cf FIRST, always. A malformed file under /etc/sudoers.d breaks sudo
# for every user on the box, and the breakage only surfaces the next time
# somebody needs it.
REPO_SUDOERS="${PROJ_PATH}/aws/nginx/sudoers.d/mojo-edge"
if [[ -f "$REPO_SUDOERS" ]]; then
    if visudo -cf "$REPO_SUDOERS" >/dev/null; then
        install -m 0440 -o root -g root "$REPO_SUDOERS" /etc/sudoers.d/mojo-edge
        log "  installed /etc/sudoers.d/mojo-edge"
    else
        log "ERROR: $REPO_SUDOERS failed visudo -cf — refusing to install it."
        exit 1
    fi
fi

# ── Systemd units, var dirs, jobs cron ───────────────────────────────────────
# Packaged convergence, not a local copy: django-mojo is reinstalled on every
# deploy, so a fix to any of these three actions reaches this node without the
# project re-copying anything. Idempotent — a converged node reports
# "nothing to change" and writes nothing.
#
# The jobs cron it writes keeps naming ${PROJ_PATH}/bin/jobman, not the module
# behind it. A cron line naming a packaged module would freeze that module's
# name in /etc/cron.d on every node forever, and there is no cron-convergence
# plane to correct it; bin/jobman is a launcher inside the clone update.sh
# refreshes on every deploy, so it stays correctable.
log "Converging node (systemd units, var dirs, jobs cron)..."
python3 -m mojo.deploy.node_setup --root "$PROJ_PATH" --units-dir "${PROJ_PATH}/var/deploy/systemd"

# var/edge is the edge plane's root (EDGE_ROOT). ec2-user owns it because the
# job engine — which runs the edge installer — is ec2-user. Created here
# rather than by node_setup: it is a per-deployment opt-in, not a var/ dir
# every django-mojo node has.
#
# The var sweep below re-groups this to www along with everything else. That is
# harmless and deliberate — see the note there — but the mode is set HERE,
# because the sweep prunes var/edge and will not touch it again.
mkdir -p "${PROJ_PATH}/var/edge"
chown ec2-user:ec2-user "${PROJ_PATH}/var/edge"
chmod 0755 "${PROJ_PATH}/var/edge"

# ── Certificate renewal cron ─────────────────────────────────────────────────
# The single-node path: a plain certbot renew, LOGGED. Not --quiet — a silent
# renew cron is how a broken certbot looks exactly like a healthy one for the
# forty days it takes the certificate to expire. This overwrites the --quiet
# weekly cron ec2_bootstrap.sh installs before the repo exists.
#
# Safe to leave running once the edge plane is on: certbot lineages live under
# /etc/letsencrypt and edge material under var/edge/generations, so the two
# cannot collide. PATH keeps /usr/local/bin — that is where certbot's venv
# symlink lives.
cat > /etc/cron.d/1_certbot <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 8 * * * root certbot renew --post-hook "systemctl reload nginx" >> ${PROJ_PATH}/var/logs/certbot.log 2>&1
EOF

# ── Var directories ───────────────────────────────────────────────────────────
# ec2-user owns (writes logs, pids, config), www group reads (uvicorn/nginx)
# setgid (2xxx) ensures new files/dirs inherit the www group
#
# var/edge is PRUNED out of both chmod sweeps: edge generations hold private
# keys at 0600 inside 0700 directories, and 2775/0664 would hand every one of
# them to the www group — the account nginx and uvicorn run as. The chown
# needs no exclusion: edge files are already ec2-user-owned, and at 0600/0700
# the group bits grant nothing no matter which group is named.
log "Setting var directory ownership..."
chown -R ec2-user:www "${PROJ_PATH}/var"
find "${PROJ_PATH}/var" -path "${PROJ_PATH}/var/edge" -prune -o -type d -exec chmod 2775 {} +
find "${PROJ_PATH}/var" -path "${PROJ_PATH}/var/edge" -prune -o -type f -exec chmod 0664 {} +

log ""
log "Project deploy complete."
log ""
log "Remaining steps:"
log "  1. echo 'prod' > ${PROJ_PATH}/var/profile"
log "  2. Edit ${PROJ_PATH}/var/django.conf with DB/cache/AWS credentials"
log "  3. python3 ${PROJ_PATH}/bin/manage.py migrate"
log "  4. Certificates —"
log "     single node: sudo certbot --nginx -d yourdomain.com"
log "     fleet:       issue in dnsman; the edge plane installs it on every node."
log "                  See docs/django_developer/deployment/provisioning.md."
log "  5. sudo systemctl enable --now mojo-asgi"

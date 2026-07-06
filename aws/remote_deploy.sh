#!/bin/bash
# Remote Deploy — drive the whole EC2 setup from your laptop over SSH.
#
# Chains together, against a single running instance you already created and
# have SSH access to (standard AL2023 AMI, ec2-user, key you downloaded):
#   1. ec2_bootstrap.sh   (system packages, users, nginx, ssh hardening)
#   2. gh deploy key      (registers the generated ec2-user key as a read-only
#                          GitHub deploy key on the CORE APP repo, then clones
#                          + runs ec2_deploy.sh — this is the key a future
#                          GitHub webhook would also authenticate as to
#                          auto-update /opt/api. The `deploy` user's key is
#                          separate and scoped to static sites under WEB_ROOT
#                          — not touched by this script)
#   3. mojo-ossec install (rsyncs a local mojo-ossec checkout and installs it)
#
# Usage:
#   aws/remote_deploy.sh <hostname> [options]
#
# Options:
#   --key <path>        SSH private key, e.g. the .pem you downloaded (-i)
#   --user <user>       Remote SSH user (default: ec2-user)
#   --repo <owner/repo> GitHub repo for the app (e.g. NativeMojo/myapp).
#                       If given: adds a read-only deploy key via `gh`, then
#                       clones git@github.com:<owner/repo>.git to PROJ_PATH
#                       and runs its aws/ec2_deploy.sh. Omit to stop after
#                       bootstrap and do the app deploy yourself.
#   --ossec <path>      Local mojo-ossec checkout to install (default:
#                       ../mojo-ossec next to this repo)
#   --skip-ossec        Don't install mojo-ossec
#   --skip-bootstrap    Skip ec2_bootstrap.sh (host already bootstrapped)
#
# Bootstrap env passthrough (see ec2_bootstrap.sh for details):
#   PROJ_PATH, TARGET_HOSTNAME, REMOVE_SSM, PYTHON_VER, POSTGRES_VER
#
# Example:
#   TARGET_HOSTNAME=api.example.com aws/remote_deploy.sh 1.2.3.4 \
#       --key ~/.ssh/myproject-us-west-2.pem \
#       --repo NativeMojo/myproject

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

HOST=""
SSH_USER="ec2-user"
SSH_KEY=""
REPO=""
OSSEC_PATH="$(cd "${SCRIPT_DIR}/../../mojo-ossec" 2>/dev/null && pwd || true)"
SKIP_OSSEC="n"
SKIP_BOOTSTRAP="n"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 1; }

[[ $# -eq 0 ]] && usage
HOST="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) SSH_KEY="$2"; shift 2 ;;
        --user) SSH_USER="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --ossec) OSSEC_PATH="$2"; shift 2 ;;
        --skip-ossec) SKIP_OSSEC="y"; shift ;;
        --skip-bootstrap) SKIP_BOOTSTRAP="y"; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
SSH_TARGET="${SSH_USER}@${HOST}"

ssh_run() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

log "Target: $SSH_TARGET"
ssh_run "true" || die "Cannot SSH to $SSH_TARGET. Check hostname/--key/--user/security group."

PROJ_PATH="${PROJ_PATH:-/opt/api}"

# ── 1. ec2_bootstrap.sh ───────────────────────────────────────────────────────
EC2USER_PUBKEY=""
if [[ "$SKIP_BOOTSTRAP" == "y" ]]; then
    log "Skipping bootstrap (--skip-bootstrap)."
else
    log "Running ec2_bootstrap.sh on $HOST (this takes a few minutes)..."
    BOOT_LOG="$(mktemp)"
    ssh_run "sudo \
        PROJ_PATH='${PROJ_PATH}' \
        TARGET_HOSTNAME='${TARGET_HOSTNAME:-}' \
        REMOVE_SSM='${REMOVE_SSM:-n}' \
        PYTHON_VER='${PYTHON_VER:-3.12}' \
        POSTGRES_VER='${POSTGRES_VER:-}' \
        bash -s" < "${SCRIPT_DIR}/ec2_bootstrap.sh" | tee "$BOOT_LOG"
    EC2USER_PUBKEY="$(grep -m1 '^ssh-ed25519' "$BOOT_LOG" || true)"
    rm -f "$BOOT_LOG"
    log "Bootstrap complete."
fi

# ── 2. gh deploy key + app deploy ─────────────────────────────────────────────
# Uses ec2-user's key (core app repo → /opt/api), not the `deploy` user's key
# (static sites → WEB_ROOT, untouched by this script).
if [[ -z "$REPO" ]]; then
    log "No --repo given — skipping deploy key + app deploy. Clone manually and run aws/ec2_deploy.sh."
else
    if [[ -z "$EC2USER_PUBKEY" ]]; then
        log "Fetching ec2-user public key from $HOST..."
        EC2USER_PUBKEY="$(ssh_run "sudo cat /home/ec2-user/.ssh/id_ed25519.pub" || true)"
    fi
    [[ -z "$EC2USER_PUBKEY" ]] && die "No ec2-user public key found on $HOST — run bootstrap first."

    GH_DEPLOY_KEY_OK=0
    if command -v gh &>/dev/null; then
        log "Registering read-only deploy key on $REPO via gh..."
        KEY_FILE="$(mktemp)"
        echo "$EC2USER_PUBKEY" > "$KEY_FILE"
        if gh repo deploy-key add "$KEY_FILE" --repo "$REPO" --title "ec2-user@${HOST}"; then
            GH_DEPLOY_KEY_OK=1
        fi
        rm -f "$KEY_FILE"
    fi

    # `gh` commonly can't do this even when installed: it's often authenticated
    # as a personal account with no access to the org/repo being deployed (a
    # 404, not an auth prompt — gh gives no signal to tell the two apart). The
    # manual fallback below is the normal path, not a rare edge case, so it
    # always gets the exact key + exact steps, never just "try gh again".
    if [[ "$GH_DEPLOY_KEY_OK" -ne 1 ]]; then
        log ""
        log "=========================================================="
        log " Deploy key needs to be added manually"
        log "=========================================================="
        log " gh couldn't add it automatically (not installed, or"
        log " authenticated as an account without access to $REPO)."
        log ""
        log " 1. Open: https://github.com/${REPO}/settings/keys"
        log " 2. Click 'Add deploy key'"
        log " 3. Title:      ec2-user@${HOST}"
        log " 4. Key:"
        log "      $EC2USER_PUBKEY"
        log " 5. Leave 'Allow write access' UNCHECKED (read-only clone only)"
        log " 6. Click 'Add key'"
        log ""
        log " Then re-run this script with --skip-bootstrap to continue"
        log " (bootstrap already completed, this will just retry the clone)."
        log "=========================================================="
        log ""
    fi

    log "Cloning $REPO to ${PROJ_PATH} and running ec2_deploy.sh on $HOST..."
    if ! ssh_run "sudo -u ec2-user bash -s" <<REMOTE
set -euo pipefail
GIT_SSH_COMMAND="ssh -i /home/ec2-user/.ssh/id_ed25519 -o StrictHostKeyChecking=no"
export GIT_SSH_COMMAND
if [[ -d "${PROJ_PATH}/.git" ]]; then
    echo "Repo already present, pulling..."
    cd "${PROJ_PATH}" && git pull
else
    # Never "rm -rf \${PROJ_PATH}" here — var/django.conf, var/profile, and
    # var/ops.json are pushed there BEFORE this runs (see
    # setup_ec2_environment() in aws/deploy.py) and are gitignored, so a
    # fresh clone's working tree would never recreate them if deleted.
    # Initializing git in-place instead leaves untracked files alone.
    echo "Cloning git@github.com:${REPO}.git (preserving any existing var/ contents)..."
    sudo mkdir -p "${PROJ_PATH}"
    sudo chown ec2-user:ec2-user "${PROJ_PATH}"
    cd "${PROJ_PATH}"
    git init -q
    git remote add origin "git@github.com:${REPO}.git"
    git fetch origin
    git checkout -f -B main origin/main
fi
REMOTE
    then
        if [[ "$GH_DEPLOY_KEY_OK" -ne 1 ]]; then
            die "Clone failed — almost certainly the deploy key from the instructions above isn't added yet. Add it, then re-run with --skip-bootstrap."
        else
            die "Clone failed even though gh reported the deploy key was added. Check https://github.com/${REPO}/settings/keys and re-run with --skip-bootstrap."
        fi
    fi
    ssh_run "sudo bash -c 'chown -R ec2-user:www \"${PROJ_PATH}\" && PROJ_PATH=\"${PROJ_PATH}\" bash \"${PROJ_PATH}/aws/ec2_deploy.sh\"'"
    log "App deploy complete."
fi

# ── 3. mojo-ossec ─────────────────────────────────────────────────────────────
if [[ "$SKIP_OSSEC" == "y" ]]; then
    log "Skipping mojo-ossec (--skip-ossec)."
elif [[ -z "$OSSEC_PATH" || ! -x "${OSSEC_PATH}/install_ec2.sh" ]]; then
    log "WARN: mojo-ossec checkout not found (looked in: ${OSSEC_PATH:-<none>}). Pass --ossec <path> or --skip-ossec."
else
    log "Installing mojo-ossec on $HOST via ${OSSEC_PATH}/install_ec2.sh..."
    ( cd "$OSSEC_PATH" && ./install_ec2.sh "$HOST" )
    log "mojo-ossec install complete."
fi

log ""
log "Done. Remaining manual steps if not already set:"
log "  1. echo 'prod' > ${PROJ_PATH}/var/profile"
log "  2. Edit ${PROJ_PATH}/var/django.conf with DB/cache/AWS credentials"
log "  3. ssh ${SSH_TARGET} sudo python3 ${PROJ_PATH}/bin/manage.py migrate"
log "  4. ssh ${SSH_TARGET} sudo certbot --nginx -d yourdomain.com"
log "  5. ssh ${SSH_TARGET} sudo systemctl enable --now mojo-asgi"

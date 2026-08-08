#!/bin/bash
# Harness for the node provisioning plane (maestro item #1611, formerly
# test_certbot_plane.sh for #1599).
#
# The skeleton is a template: a project downloads it once, so any logic it
# carries is frozen at download time and never receives a fix. This harness
# holds that line. It asserts that the copies are gone, that nothing still
# points at them, that the launchers point at the packaged modules, and that
# the node prerequisites the dnsman/edge certificate plane needs are actually
# provisioned.
#
# It is a CONTENT harness. The provisioning scripts cannot be executed (dnf,
# alternatives, sshd -t, systemctl), so their guarantees are asserted against
# their text, plus real syntax gates at the end. The one thing that IS executed
# is `visudo -cf` against the sudoers asset — a malformed file there breaks sudo
# on every node in the fleet.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_eq() { # actual expected label
    if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got: $1, want: $2)"; fi
}
assert_has() { # file pattern label
    if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3 (no '$2' in $(basename "$1"))"; fi
}
assert_lacks() { # file pattern label
    if grep -q -- "$2" "$1" 2>/dev/null; then fail "$3 ('$2' present in $(basename "$1"))"; else ok "$3"; fi
}

BOOTSTRAP="$REPO/aws/ec2_bootstrap.sh"
WWW="$REPO/aws/ec2_www.sh"
DEPLOY_SH="$REPO/aws/ec2_deploy.sh"
DEPLOY_PY="$REPO/aws/deploy.py"
SUDOERS="$REPO/aws/nginx/sudoers.d/mojo-edge"
SERVICE="$REPO/aws/nginx/systemd/config-sync.service"
TIMER="$REPO/aws/nginx/systemd/config-sync.timer"
APP_CONF="$REPO/aws/nginx/conf.d/app.conf"
MOJO_CONF="$REPO/aws/nginx/conf.d/mojo.conf"
PROD_SETTINGS="$REPO/config/settings/prod/__init__.py"

# Every file #1611 deleted: three logic copies whose packaged replacements ship
# in django-mojo, and seven orphans nothing referenced.
DELETED_PATHS="aws/certbot_sync.py aws/check_setup.py aws/config_sync.py
aws/setup_dns.py aws/set_hostname.sh bin/tasks.py bin/django_prod bin/_wsgi.py
bin/asgi_prod bin/run_dev_server"

# Their basenames, for the reference sweeps below. A path-qualified mention is
# caught by the same pattern.
DELETED_NAMES="certbot_sync.py check_setup.py config_sync.py setup_dns.py
set_hostname.sh tasks.py django_prod _wsgi.py asgi_prod run_dev_server"
NAME_RE="$(echo "$DELETED_NAMES" | tr -s '[:space:]' '|' | sed 's/|$//')"

# ── Group A: the copies are gone ─────────────────────────────────────────────

echo "no logic copy or dead script survives in the repo"
for rel in $DELETED_PATHS; do
    if [ -e "$REPO/$rel" ]; then
        fail "$rel still exists"
    else
        ok "$rel is gone"
    fi
done

# ── Group B: nothing still points at them ────────────────────────────────────
#
# Two sweeps, because the two file classes fail differently. In code and config
# a deleted basename is ALWAYS a live reference. In prose it usually is not —
# the migration notes name certbot_sync.py precisely to say it is gone — so
# there the failure is a line that still tells somebody to RUN one.

echo "no code or config file references a deleted script"
hits="$(grep -rn --exclude=test_node_plane.sh --exclude='*.md' \
        --exclude-dir=__pycache__ -I -E "$NAME_RE" \
        "$REPO/aws" "$REPO/bin" "$REPO/config" "$REPO/tests" 2>/dev/null)"
if [ -z "$hits" ]; then
    ok "aws/ bin/ config/ tests/ name none of the deleted files"
else
    fail "a code/config file still names a deleted file: $hits"
fi

echo "no document still tells an operator to run a deleted script"
prose_hits="$(grep -rnE "(sudo |python3? |bash |\./)[^|]*($NAME_RE)" \
        "$REPO/docs" "$REPO/README.md" "$REPO/CLAUDE.md" \
        "$REPO/aws/README.md" "$REPO/aws/terraform/README.md" 2>/dev/null)"
if [ -z "$prose_hits" ]; then
    ok "the docs mention the deleted scripts only as history, never as a command"
else
    fail "a document still gives a command naming a deleted script: $prose_hits"
fi

# ── Group C: the launchers point at the packaged modules ─────────────────────

echo "systemd: config-sync runs the packaged module, by absolute interpreter"
assert_has "$SERVICE" "^ExecStart=/usr/bin/python3 -m mojo.deploy.config_sync$" \
    "config-sync.service execs python3 -m mojo.deploy.config_sync"
assert_has "$SERVICE" "^Documentation=https://" "config-sync.service documents a URL, not a local path"
assert_has "$TIMER" "^Documentation=https://" "config-sync.timer documents a URL, not a local path"

echo "ec2_deploy.sh: the three convergence actions come from the package"
assert_has "$DEPLOY_SH" "python3 -m mojo.deploy.node_setup --root" \
    "ec2_deploy.sh calls the packaged node_setup"
assert_lacks "$DEPLOY_SH" "cp -f .*systemd" "it no longer copies systemd units itself"
# The cron node_setup writes still names bin/jobman, not the module behind it:
# /etc/cron.d is written once at provisioning time and there is no
# cron-convergence plane, so a module name baked in there would be permanent.
assert_lacks "$DEPLOY_SH" "cron.d/3_mojo_jobs" "and the jobs cron is node_setup's job now"

# ── Group D: certbot, still isolated, still audible ──────────────────────────

echo "bootstraps: certbot is isolated from the application's Python"
for f in "$BOOTSTRAP" "$WWW"; do
    n="$(basename "$f")"
    sed -n '/^pip install \\/,/^$/p' "$f" > "$TMP/pipblock"
    assert_lacks "$TMP/pipblock" "certbot" "$n does not pip-install certbot alongside django-mojo"
    assert_has "$f" "python\${PYTHON_VER} -m venv --without-pip /opt/certbot" "$n creates the /opt/certbot venv"
    assert_has "$f" "/opt/certbot/bin/pip install certbot certbot-nginx" "$n installs certbot into that venv"
    assert_has "$f" "ln -snf /opt/certbot/bin/certbot /usr/local/bin/certbot" "$n symlinks it onto PATH"
done
sed -n '/── Certbot, in its own venv/,/ln -snf \/opt\/certbot/p' "$BOOTSTRAP" > "$TMP/venv_bootstrap"
sed -n '/── Certbot, in its own venv/,/ln -snf \/opt\/certbot/p' "$WWW" > "$TMP/venv_www"
if [ -s "$TMP/venv_bootstrap" ] && diff -q "$TMP/venv_bootstrap" "$TMP/venv_www" >/dev/null; then
    ok "the two bootstrap twins carry an identical venv block (no drift)"
else
    fail "ec2_bootstrap.sh and ec2_www.sh venv blocks differ"
fi

echo "crons: every certbot cron can find certbot"
for f in "$BOOTSTRAP" "$WWW" "$DEPLOY_SH"; do
    n="$(basename "$f")"
    bad="$(awk '/^cat > \/etc\/cron.d\/[14]_certbot/ {want=1; next}
                want && /^PATH=/ {if ($0 !~ /\/usr\/local\/bin/) print; want=0}' "$f")"
    if [ -z "$bad" ]; then
        ok "$n: every certbot cron PATH includes /usr/local/bin"
    else
        fail "$n: a certbot cron PATH omits /usr/local/bin ($bad)"
    fi
done

echo "renewal: the single-node path is a plain renew, and it is logged"
assert_has "$DEPLOY_SH" "root certbot renew" "ec2_deploy.sh's 1_certbot is a plain certbot renew"
assert_has "$DEPLOY_SH" "var/logs/certbot.log" "and it redirects into var/logs, not into the void"
# --quiet is the #1599 defect: a silent renew makes a broken certbot look
# exactly like a healthy one for the forty days to expiry. The bootstraps keep
# it only because they run before /opt/api exists and have nowhere to log.
renew_line="$(grep 'root certbot renew' "$DEPLOY_SH")"
case "$renew_line" in
    *--quiet*) fail "ec2_deploy.sh's renew cron is --quiet again" ;;
    *)         ok "ec2_deploy.sh's renew cron is not --quiet" ;;
esac
assert_has "$BOOTSTRAP" "root certbot renew" "the pre-clone bootstrap keeps its own plain renew (it has no /opt/api yet)"
assert_has "$WWW" "root certbot renew" "so does its curl-one-liner twin"

# ── Group E: the cert plane is gone, provisioning half included ──────────────

echo "ec2_deploy.sh: no trace of the S3 cert plane"
for pat in "PRIMARY_BALANCER_HOST" "AWS_CERT_BUCKET" "certbot_sync" "4_certbot_sync" "ops.json"; do
    assert_lacks "$DEPLOY_SH" "$pat" "ec2_deploy.sh never mentions $pat"
done

echo "deploy.py: the keys and the bucket that served the cert plane are gone"
# A conf key nothing reads is worse than no key — it tells the next operator
# that cert sync is armed.
for pat in "AWS_CERT_BUCKET" "PRIMARY_BALANCER_HOST" "LOAD_BALANCER_DOMAIN" \
           "setup_cert_bucket" "cert-bucket" "build_ops_json" "ops.json"; do
    assert_lacks "$DEPLOY_PY" "$pat" "deploy.py never mentions $pat"
done
assert_lacks "$REPO/aws/terraform/outputs.tf" "PRIMARY_BALANCER_HOST = " \
    "the terraform django.conf fragment writes no dead cert-plane key"

echo "nginx: the vhosts stay self-contained so every node can serve them"
# A real include DIRECTIVE, not a comment warning against one (app.conf has
# the latter on purpose).
if grep -rqE '^[[:space:]]*include[[:space:]][^;]*options-ssl-nginx\.conf' "$REPO/aws/nginx/"; then
    fail "an nginx config includes options-ssl-nginx.conf (breaks nginx -t on other nodes)"
else
    ok "no nginx config includes options-ssl-nginx.conf"
fi
assert_has "$APP_CONF" "mojo.apps.edge" "app.conf points the fleet path at the edge plane"
assert_has "$APP_CONF" "certbot --nginx" "app.conf keeps the single-node certbot instruction"

# ── Group F: the edge plane's node prerequisites ─────────────────────────────

echo "sudoers: exactly two argument-less absolute-path rules, for ec2-user"
rules="$(grep -c '^ec2-user ALL=(root) NOPASSWD: /' "$SUDOERS" 2>/dev/null)"
assert_eq "$rules" "2" "the file carries exactly two rules"
non_rule="$(grep -vcE '^(#|$|ec2-user ALL=\(root\) NOPASSWD: /)' "$SUDOERS" 2>/dev/null)"
assert_eq "$non_rule" "0" "and nothing else — no other user, no other form"
assert_has "$SUDOERS" "^ec2-user ALL=(root) NOPASSWD: /usr/sbin/nginx -t$" "rule 1 is the live-config nginx -t"
assert_has "$SUDOERS" "^ec2-user ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx$" "rule 2 is the nginx reload"
# `nginx -t -c <app-writable path>` makes that file nginx's MAIN config, where
# load_module is legal and gets dlopen()ed as root. The staged check runs
# unprivileged for exactly that reason; a rule here would be a root escalation,
# and the generation hash in the path means it could never be narrowed away.
assert_lacks "$SUDOERS" "\-c" "no staged-check rule (nginx -t -c would be a root escalation)"
assert_lacks "$SUDOERS" "[*]" "no wildcard in any rule"
assert_lacks "$SUDOERS" "^www " "the app-server user www is granted nothing"

echo "ec2_deploy.sh: the sudoers file is validated before it is installed"
assert_has "$DEPLOY_SH" "visudo -cf" "visudo -cf gates the install"
# The gate is worthless if the install can still happen when it fails.
gate="$(sed -n '/visudo -cf/,/^fi$/p' "$DEPLOY_SH")"
if echo "$gate" | grep -q "install -m 0440 -o root -g root" && echo "$gate" | grep -q "exit 1"; then
    ok "it installs 0440 root:root only on success, and aborts otherwise"
else
    fail "the visudo gate does not clearly guard the install"
fi

echo "nginx: the edge include ships, and is inert until a generation exists"
assert_has "$MOJO_CONF" "^include /opt/api/var/edge/current/conf.d/\*\.conf;$" \
    "conf.d/mojo.conf is the one-line edge include"
assert_eq "$(wc -l < "$MOJO_CONF" | tr -d ' ')" "1" "and it is exactly one line"

echo "ec2_deploy.sh: EDGE_ROOT is created, owned by the account that writes it"
assert_has "$DEPLOY_SH" 'mkdir -p "${PROJ_PATH}/var/edge"' "var/edge is created"
assert_has "$DEPLOY_SH" 'chown ec2-user:ec2-user "${PROJ_PATH}/var/edge"' \
    "and owned by ec2-user — the account the job engine runs as"

echo "ec2_deploy.sh: the var sweep cannot reach edge private keys"
# Edge generations hold 0600 keys in 0700 dirs. The sweep's 2775/0664 would
# hand every one of them to the www group, which is what nginx and uvicorn run
# as. -prune, not -not -path: the latter still matches var/edge itself.
sweep="$(grep -c 'var/edge" -prune -o -type [df] -exec chmod' "$DEPLOY_SH")"
assert_eq "$sweep" "2" "both chmod sweeps prune var/edge"
if grep -qE '^find "\$\{PROJ_PATH\}/var" -type [df] -exec chmod' "$DEPLOY_SH"; then
    fail "an unpruned chmod sweep survives"
else
    ok "no unpruned chmod sweep survives"
fi

echo "settings: the opt-in is one edit, and the fail-closed setting is named"
assert_has "$PROD_SETTINGS" "^EDGE_CONVERGE_ENABLED = False$" "convergence ships off"
assert_has "$PROD_SETTINGS" "^# EDGE_RESERVED_SERVER_NAMES = " \
    "EDGE_RESERVED_SERVER_NAMES ships as a commented placeholder"
assert_has "$PROD_SETTINGS" "fails closed" "with the fail-closed warning next to it"

# ── Group G: syntax gates ────────────────────────────────────────────────────

echo "syntax"
for f in "$BOOTSTRAP" "$WWW" "$DEPLOY_SH" "$REPO/bin/jobman"; do
    bash -n "$f" 2>"$TMP/syntax.err"
    assert_eq "$?" 0 "$(basename "$f") parses"
done
( cd "$REPO" && python3 -m py_compile aws/deploy.py ) 2>"$TMP/syntax.err"
assert_eq "$?" 0 "deploy.py compiles"
if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$SUDOERS" >/dev/null 2>"$TMP/visudo.err"
    assert_eq "$?" 0 "the sudoers file passes visudo -cf"
else
    ok "visudo is not present here — skipping the sudoers syntax gate"
fi

# ── result ───────────────────────────────────────────────────────────────────

echo
echo "test_node_plane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Harness for aws/post_deploy.sh (maestro item #1572).
#
# Runs the REAL script against a throwaway PROJ_PATH with the NGINX_ETC /
# SYSTEMD_ETC seams pointed into the temp dir and every external command
# stubbed on PATH. The one property the fleet cutover depends on gets its own
# test: BARE invocation must complete the legacy sequence, because the final
# legacy broadcast executes the OLD update.sh, which invokes this NEW file
# with no arguments.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
STUB="$TMP/stubs"
CTL="$TMP/ctl"
export CALLLOG="$TMP/calls.log"
export STUBCTL="$CTL"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got: $1, want: $2)"; fi
}
assert_in_log() {
    if grep -q "$1" "$CALLLOG" 2>/dev/null; then ok "$2"; else fail "$2 (no '$1' in log)"; fi
}
assert_not_in_log() {
    if grep -q "$1" "$CALLLOG" 2>/dev/null; then fail "$2 ('$1' present)"; else ok "$2"; fi
}

setup_env() {
    rm -rf "$PROJ" "$STUB" "$CTL" "$TMP/nginx_etc" "$TMP/systemd_etc"
    mkdir -p "$PROJ/var" "$PROJ/bin" "$PROJ/aws/nginx/systemd" "$PROJ/aws/nginx/sec.d" \
             "$STUB" "$CTL" "$TMP/nginx_etc" "$TMP/systemd_etc"
    : > "$CALLLOG"

    cp "$REPO/aws/post_deploy.sh" "$PROJ/aws/post_deploy.sh"
    # install_file dies on a missing source — the real configs must exist.
    echo "# test" > "$PROJ/aws/nginx/nginx.conf"
    echo "# test" > "$PROJ/aws/nginx/asgi.inc"
    echo "# test" > "$PROJ/aws/nginx/django.inc"
    : > "$PROJ/bin/manage.py"

    for cmd in pip python3 nginx systemctl curl; do
        cat > "$STUB/$cmd" <<EOF
#!/bin/bash
echo "CMD $cmd \$*" >> "\$CALLLOG"
ctl="\$STUBCTL/$cmd.exit"
[ -f "\$ctl" ] && exit "\$(cat "\$ctl")"
exit 0
EOF
        chmod +x "$STUB/$cmd"
    done
}

run_post_deploy() { # args...
    ( cd "$TMP" && PROJ_PATH="$PROJ" NGINX_ETC="$TMP/nginx_etc" \
        SYSTEMD_ETC="$TMP/systemd_etc" PATH="$STUB:$PATH" \
        bash "$PROJ/aws/post_deploy.sh" "$@" )
}

# ── tests ────────────────────────────────────────────────────────────────────

echo "post_deploy.sh: --framework pins the install; bare upgrades"
setup_env
run_post_deploy --framework 9.9.9 >/dev/null 2>&1
assert_eq "$?" 0 "--framework run exits 0"
assert_in_log "CMD pip install django-mojo==9.9.9" "pinned install argv"
setup_env
run_post_deploy >/dev/null 2>&1
assert_eq "$?" 0 "bare run exits 0"
assert_in_log "CMD pip install --upgrade django-mojo" "bare run upgrades to latest"

echo "post_deploy.sh: --migrate runs migrate_locked; absent runs no migration"
setup_env
run_post_deploy --framework 9.9.9 --migrate >/dev/null 2>&1
assert_eq "$?" 0 "--migrate run exits 0"
assert_in_log "manage.py migrate_locked --noinput" "migrate_locked invoked"
setup_env
run_post_deploy --framework 9.9.9 >/dev/null 2>&1
assert_not_in_log "migrate" "no migration of any kind without --migrate"

echo "post_deploy.sh: BARE invocation completes the legacy sequence (cutover-load-bearing)"
setup_env
run_post_deploy >/dev/null 2>&1
assert_eq "$?" 0 "bare invocation exits 0"
assert_in_log "CMD nginx -t" "nginx config test ran"
assert_in_log "CMD systemctl restart mojo-asgi" "app restarted"
assert_in_log "CMD curl" "the /api/version probe ran"
if [ -f "$TMP/nginx_etc/nginx.conf" ]; then
    ok "nginx.conf landed in the NGINX_ETC seam"
else
    fail "nginx.conf missing from the NGINX_ETC seam"
fi
assert_not_in_log "migrate" "bare invocation never migrates"

echo "post_deploy.sh: a failed step aborts before the restart (die-loudly)"
setup_env
echo "1" > "$CTL/pip.exit"
run_post_deploy --framework 9.9.9 >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "failed install exits non-zero"; else fail "failed install exited 0"; fi
assert_not_in_log "systemctl restart mojo-asgi" "no restart after a failed install"

# ── result ───────────────────────────────────────────────────────────────────

echo
echo "test_post_deploy_sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Harness for the prod profile marker on the legacy aws/deploy.py paths
# (maestro item #9315).
#
# django-mojo's settings loader boots `settings.local` (SSL redirect off,
# local database) whenever var/profile is absent. The full deploy.py run
# writes "prod" in ec2-setup, but other paths did not:
#
#   * --step bake-ami imaged node1 whatever its profile, so every clone of a
#     markerless node1 booted settings.local;
#   * the first-time --step ec2 user data ran the installer with no profile,
#     from an unpinned gist;
#   * ec2_deploy.sh / remote_deploy.sh only printed "echo 'prod'" as a step.
#
# The bake pre-check is EXECUTED: it is extracted from deploy.py, pointed at a
# temp root and run under bash with systemctl stubbed. The rest is asserted
# against the text, like test_node_plane.sh.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEPLOY_PY="$REPO/aws/deploy.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got: $1, want: $2)"; fi; }
assert_has() { if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3 (no '$2' in $(basename "$1"))"; fi; }
assert_lacks() { if grep -q -- "$2" "$1" 2>/dev/null; then fail "$3 ('$2' present in $(basename "$1"))"; else ok "$3"; fi; }

# ── bake-ami refuses a node1 whose profile is not prod ─────────────────────

echo "bake-ami: the pre-bake check (executed)"
python3 - "$DEPLOY_PY" "$TMP/prebake.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index("def bake_ami("):]
script = re.search(r'input="""(.*?)""",', body, re.S).group(1)
open(sys.argv[2], "w").write(script)
PY
mkdir -p "$TMP/stub" "$TMP/root/opt/api/var/pids"
cat > "$TMP/stub/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$TMP/calls.log"
EOF
chmod +x "$TMP/stub/systemctl"
sed "s#/opt/api#$TMP/root/opt/api#g" "$TMP/prebake.sh" > "$TMP/prebake.root.sh"

run_prebake() {
    : > "$TMP/calls.log"
    PATH="$TMP/stub:$PATH" bash "$TMP/prebake.root.sh" >/dev/null 2>"$TMP/prebake.err"
}

rm -f "$TMP/root/opt/api/var/profile"
run_prebake; rc=$?
assert_eq "$rc" 3 "no var/profile: the pre-bake check exits 3"
assert_lacks "$TMP/calls.log" "enable" "no var/profile: nothing is enabled before refusing"
assert_has "$TMP/prebake.err" "does not read prod" "no var/profile: the refusal says why"

echo local > "$TMP/root/opt/api/var/profile"
run_prebake; rc=$?
assert_eq "$rc" 3 "profile 'local': the pre-bake check exits 3"

echo prod > "$TMP/root/opt/api/var/profile"
run_prebake; rc=$?
assert_eq "$rc" 0 "profile 'prod': the pre-bake check passes"
assert_has "$TMP/calls.log" "enable --now nginx crond rsyslog mojo-asgi" "profile 'prod': services are enabled as before"

# ── first-time --step ec2 user data ─────────────────────────────────────────

echo "--step ec2: the first-time user data"
python3 - "$DEPLOY_PY" "$TMP/userdata.txt" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("# First-time node (no golden image yet)")
open(sys.argv[2], "w").write(src[start:src.index('"""', src.index('user_data = f"""', start) + 16)])
PY
profile_line=$(grep -n "echo prod > /opt/api/var/profile" "$TMP/userdata.txt" | head -1 | cut -d: -f1)
curl_line=$(grep -n "curl -fsSL https://gist" "$TMP/userdata.txt" | head -1 | cut -d: -f1)
if [ -n "$profile_line" ] && [ -n "$curl_line" ] && [ "$profile_line" -lt "$curl_line" ]; then
    ok "the profile is written before the installer runs"
else
    fail "the profile is written before the installer runs (profile line: ${profile_line:-none}, curl line: ${curl_line:-none})"
fi
assert_has "$TMP/userdata.txt" "raw/[0-9a-f]\{40\}/ec2_django_mojo_install.sh" "the installer gist is pinned to a revision"

# ── the shell scripts say so when the profile is missing ───────────────────

echo "ec2_deploy.sh / remote_deploy.sh"
assert_has "$REPO/aws/ec2_deploy.sh" 'var/profile" 2>/dev/null)" != "prod"' "ec2_deploy.sh checks var/profile"
assert_has "$REPO/aws/ec2_deploy.sh" "WARNING: .*does not read prod" "ec2_deploy.sh warns when it is not prod"
assert_has "$REPO/aws/remote_deploy.sh" "var/profile on the node does not read prod" "remote_deploy.sh warns when it is not prod"

# ── extract a marked block (# >>> name … # <<< name) into a script ─────────

extract_block() { # file name out
    python3 - "$1" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
start = src.index(f"# >>> {name}")
end = src.index(f"# <<< {name}", start)
open(sys.argv[3], "w").write(src[start:end])
PY
}

# systemctl / chown / jobman stubs, all logging to $TMP/calls.log.
#   STUB_ENABLED=1         `systemctl is-enabled` succeeds (a serving box)
#   STUB_SYSTEMCTL_FAIL=1  every other systemctl call fails
cat > "$TMP/stub/systemctl" <<STUB
#!/bin/bash
echo "systemctl \$*" >> "$TMP/calls.log"
if [ "\$1" = "is-enabled" ]; then [ "\${STUB_ENABLED:-0}" = 1 ]; exit \$?; fi
[ "\${STUB_SYSTEMCTL_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
cat > "$TMP/stub/chown" <<STUB
#!/bin/bash
echo "chown \$*" >> "$TMP/calls.log"
STUB
chmod +x "$TMP/stub/systemctl" "$TMP/stub/chown"
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# ── ec2_deploy.sh writes prod only on a box that has never served ──────────

echo "ec2_deploy.sh: the profile block (executed)"
DEPLOY_SH="$REPO/aws/ec2_deploy.sh"
if grep -q "# >>> profile-marker" "$DEPLOY_SH" && grep -q "# >>> profile-mode" "$DEPLOY_SH"; then
    extract_block "$DEPLOY_SH" "profile-marker" "$TMP/marker.sh"
    extract_block "$DEPLOY_SH" "profile-mode" "$TMP/mode.sh"
    { echo 'log() { echo "$*"; }'; cat "$TMP/marker.sh"
      echo 'chmod 0664 "${PROJ_PATH}/var/profile" 2>/dev/null || true  # the var sweep'
      cat "$TMP/mode.sh"; } > "$TMP/ec2_deploy_block.sh"
    PROJ="$TMP/edroot"
    run_ed() { # enabled
        rm -rf "$PROJ"; mkdir -p "$PROJ/var"; : > "$TMP/calls.log"
        PATH="$TMP/stub:$PATH" STUB_ENABLED="$1" PROJ_PATH="$PROJ" \
            bash -euo pipefail "$TMP/ec2_deploy_block.sh" > "$TMP/ed.out" 2>&1
    }
    run_ed 0; rc=$?
    assert_eq "$rc" 0 "fresh box: the block exits 0"
    assert_eq "$(cat "$PROJ/var/profile" 2>/dev/null)" "prod" "fresh box gets prod"
    assert_eq "$(perm "$PROJ/var/profile")" "640" "fresh box: the marker ends 640, after the var sweep"
    assert_has "$TMP/calls.log" "chown ec2-user:www $PROJ/var/profile" "fresh box: the marker is chowned ec2-user:www"

    run_ed 1; rc=$?
    assert_eq "$rc" 0 "serving box: the block exits 0"
    if [ -e "$PROJ/var/profile" ]; then fail "serving box is left alone (a marker was written)"; else ok "serving box is left alone"; fi

    for existing in local prod; do
        rm -rf "$PROJ"; mkdir -p "$PROJ/var"; echo "$existing" > "$PROJ/var/profile"; : > "$TMP/calls.log"
        PATH="$TMP/stub:$PATH" STUB_ENABLED=0 PROJ_PATH="$PROJ" \
            bash -euo pipefail "$TMP/ec2_deploy_block.sh" > "$TMP/ed.out" 2>&1
        assert_eq "$(cat "$PROJ/var/profile")" "$existing" "marker '$existing' is never overwritten"
        assert_lacks "$TMP/calls.log" "chown" "marker '$existing': nothing is chowned"
    done
else
    fail "ec2_deploy.sh has the profile-marker and profile-mode blocks"
fi
assert_has "$DEPLOY_SH" "does not read prod" "ec2_deploy.sh still warns on a serving box without prod"

# ── golden-clone user data writes prod and restarts the app ────────────────

echo "--step ec2 golden clone: the profile block (executed)"
if grep -q "# >>> golden-profile" "$DEPLOY_PY"; then
    extract_block "$DEPLOY_PY" "golden-profile" "$TMP/golden.raw"
    assert_lacks "$TMP/golden.raw" "[{}]" "the block holds no f-string braces"
    GROOT="$TMP/groot"
    sed "s#/opt/api#$GROOT/opt/api#g" "$TMP/golden.raw" > "$TMP/golden.sh"
    run_golden() { # systemctl_fail
        : > "$TMP/calls.log"
        PATH="$TMP/stub:$PATH" STUB_SYSTEMCTL_FAIL="$1" \
            bash -euo pipefail "$TMP/golden.sh" > "$TMP/golden.out" 2>&1
    }
    reset_groot() {
        rm -rf "$GROOT"; mkdir -p "$GROOT/opt/api/var" "$GROOT/opt/api/bin"
        printf '#!/bin/bash\necho "jobman $*" >> "%s"\n' "$TMP/calls.log" > "$GROOT/opt/api/bin/jobman"
        chmod +x "$GROOT/opt/api/bin/jobman"
    }
    reset_groot; run_golden 0; rc=$?
    assert_eq "$rc" 0 "no marker: the block exits 0"
    assert_eq "$(cat "$GROOT/opt/api/var/profile" 2>/dev/null)" "prod" "golden clone gets prod"
    assert_eq "$(perm "$GROOT/opt/api/var/profile")" "640" "golden clone: the marker is 640"
    assert_has "$TMP/calls.log" "systemctl try-restart mojo-asgi" "golden clone gets a restart"
    assert_has "$TMP/calls.log" "jobman restart" "golden clone: the job engines restart"

    reset_groot; echo prod > "$GROOT/opt/api/var/profile"; run_golden 0
    assert_lacks "$TMP/calls.log" "try-restart" "marker present: no restart"
    assert_lacks "$TMP/calls.log" "chown" "marker present: nothing written"

    reset_groot; echo local > "$GROOT/opt/api/var/profile"; run_golden 0
    assert_eq "$(cat "$GROOT/opt/api/var/profile")" "local" "an existing marker is never overwritten"

    reset_groot; run_golden 1; rc=$?
    assert_eq "$rc" 0 "a failing systemctl does not abort the user data"
    assert_eq "$(cat "$GROOT/opt/api/var/profile" 2>/dev/null)" "prod" "a failing systemctl still leaves prod written"
else
    fail "deploy.py golden-clone user data has the golden-profile block"
fi

echo "syntax"
bash -n "$REPO/aws/ec2_deploy.sh"; assert_eq "$?" 0 "ec2_deploy.sh parses"
bash -n "$REPO/aws/remote_deploy.sh"; assert_eq "$?" 0 "remote_deploy.sh parses"
( cd "$REPO" && python3 -m py_compile aws/deploy.py ); assert_eq "$?" 0 "deploy.py compiles"

echo
echo "test_profile_marker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

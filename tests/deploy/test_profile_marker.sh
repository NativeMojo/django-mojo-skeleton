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

echo "syntax"
bash -n "$REPO/aws/ec2_deploy.sh"; assert_eq "$?" 0 "ec2_deploy.sh parses"
bash -n "$REPO/aws/remote_deploy.sh"; assert_eq "$?" 0 "remote_deploy.sh parses"
( cd "$REPO" && python3 -m py_compile aws/deploy.py ); assert_eq "$?" 0 "deploy.py compiles"

echo
echo "test_profile_marker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

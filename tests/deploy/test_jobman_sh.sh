#!/bin/bash
# Harness for `bin/jobman` as a SHIM (maestro item #1611).
#
# The status semantics this file used to cover — ten cases of "extra" versus
# "unmanaged" instances, including the #1600 regression where a healthy engine
# was reported as an extra instance of itself — moved into django-mojo along
# with the logic they describe (`tests/test_deploy/jobman.py`). Coverage went
# where the code went; what stays here is the contract of the launcher.
#
# Three contracts, because each has a caller that breaks if it slips:
#
#   1. The argv surface is unchanged. /etc/cron.d/3_mojo_jobs runs
#      `bin/jobman start` every minute and aws/update.sh runs `./bin/jobman stop`.
#   2. Exit codes pass through. update.sh's stop runs under `set -e`.
#   3. The shim carries NO logic. The moment a pidfile path, a pgrep pattern or
#      a status string appears here, this file is a copy again — frozen at the
#      moment a project downloaded the skeleton, and unreachable by a fix.
#
# Contracts 1 and 2 are also exercised for real: `python3` is stubbed on PATH,
# so the shim runs end to end without django-mojo needing to be importable.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
STUB="$TMP/stubs"
OUT="$TMP/out.txt"
CTL="$TMP/ctl"
export STUBCTL="$CTL"

PASS=0
FAIL=0
RC=0

SHIM="$REPO/bin/jobman"

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got: $1, want: $2)"; fi
}
assert_has() { # file pattern label
    if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3 (no '$2' in $(basename "$1"))"; fi
}
assert_lacks() { # file pattern label
    if grep -q -- "$2" "$1" 2>/dev/null; then fail "$3 ('$2' present in $(basename "$1"))"; else ok "$3"; fi
}
assert_line() { # exact whole line in $OUT
    if grep -qxF "$1" "$OUT" 2>/dev/null; then ok "$2"; else fail "$2 (no exact line '$1')"; fi
}

setup_case() {
    rm -rf "$PROJ" "$STUB" "$CTL"
    mkdir -p "$PROJ/bin" "$STUB" "$CTL"
    cp "$SHIM" "$PROJ/bin/jobman"
    chmod +x "$PROJ/bin/jobman"

    # python3 stub — prints the argv the shim handed it, one word per line, and
    # exits with whatever the fixture asks for. The real module is never
    # imported, so this works on a box with no django-mojo installed.
    cat > "$STUB/python3" <<'EOF'
#!/bin/bash
for a in "$@"; do echo "ARG $a"; done
echo "CWD $PWD"
echo "DJANGO_SETTINGS_MODULE ${DJANGO_SETTINGS_MODULE:-unset}"
echo "OBJC_DISABLE_INITIALIZE_FORK_SAFETY ${OBJC_DISABLE_INITIALIZE_FORK_SAFETY:-unset}"
[ -f "$STUBCTL/python3.exit" ] && exit "$(cat "$STUBCTL/python3.exit")"
exit 0
EOF
    chmod +x "$STUB/python3"
}

run_shim() { # args...
    ( cd "$TMP" && PATH="$STUB:$PATH" bash "$PROJ/bin/jobman" "$@" ) > "$OUT" 2>&1
    RC=$?
}

# ── the shim carries no logic ────────────────────────────────────────────────

echo "bin/jobman: nothing that belongs to the packaged module lives here"
for pat in "var/pids" "pgrep" "kill -TERM" "kill -KILL" \
           "extra instances detected" "unmanaged instances detected" \
           "stale PID file" "nohup"; do
    assert_lacks "$SHIM" "$pat" "the shim contains no '$pat'"
done
# A launcher this small has no room for a case statement or a usage function
# either — both mean it started re-deriving the surface instead of forwarding it.
assert_lacks "$SHIM" "^case " "no dispatch of its own"
assert_lacks "$SHIM" "^usage()" "no usage function of its own"

lines="$(grep -cvE '^[[:space:]]*(#|$)' "$SHIM")"
if [ "$lines" -le 12 ]; then
    ok "the shim is $lines lines of code (a launcher, not a program)"
else
    fail "the shim has grown to $lines lines of code — logic is creeping back"
fi

echo "bin/jobman: it targets the packaged module, from the project root"
assert_has "$SHIM" '^exec python3 -m mojo.deploy.jobman --root "\$ROOT" "\$@"$' \
    "it execs the packaged module with --root and forwards \$@ verbatim"
assert_has "$SHIM" 'ROOT="\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")/.." && pwd)"' \
    "ROOT is derived from BASH_SOURCE, so a cron absolute path resolves right"
assert_has "$SHIM" '^cd "\$ROOT"$' "and it runs from the project root"
assert_has "$SHIM" "^export DJANGO_SETTINGS_MODULE=settings$" "settings module exported"
assert_has "$SHIM" "^export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES$" "macOS fork-safety workaround kept"
assert_has "$SHIM" "^set -euo pipefail$" "strict mode"
if [ -x "$SHIM" ]; then ok "bin/jobman is executable"; else fail "bin/jobman is not executable"; fi

# ── contract 1: the argv surface is unchanged ────────────────────────────────

echo "bin/jobman: every documented invocation reaches the module verbatim"
setup_case
run_shim status engine
assert_eq "$RC" 0 "status engine exits 0"
assert_line "ARG -m" "python3 is invoked in module mode"
assert_line "ARG mojo.deploy.jobman" "and the module is mojo.deploy.jobman"
assert_line "ARG --root" "with --root"
assert_line "ARG $PROJ" "pointed at the project root the shim derived"
assert_line "ARG status" "the verb is forwarded"
assert_line "ARG engine" "and so is the component"
assert_line "CWD $PROJ" "the module runs with the project root as cwd"
assert_line "DJANGO_SETTINGS_MODULE settings" "the settings module is in the environment"
assert_line "OBJC_DISABLE_INITIALIZE_FORK_SAFETY YES" "so is the fork-safety workaround"

# The three verbs, bare and with each component — the full surface the cron and
# update.sh depend on.
for verb in start stop status; do
    for comp in "" engine scheduler; do
        setup_case
        # shellcheck disable=SC2086
        run_shim $verb $comp
        assert_eq "$RC" 0 "'jobman $verb $comp' exits 0"
        assert_line "ARG $verb" "'jobman $verb $comp' forwards the verb"
        if [ -n "$comp" ]; then
            assert_line "ARG $comp" "'jobman $verb $comp' forwards the component"
        fi
    done
done

# ── contract 2: exit codes pass through ──────────────────────────────────────

echo "bin/jobman: the module's exit code is the shim's exit code"
# update.sh:208 runs `./bin/jobman stop` under `set -e`. A shim that swallowed
# a failure would turn a dead node into a green deploy.
for code in 1 3 7; do
    setup_case
    echo "$code" > "$CTL/python3.exit"
    run_shim stop
    assert_eq "$RC" "$code" "exit $code passes through unchanged"
done
setup_case
run_shim status
assert_eq "$RC" 0 "and success is still 0"

# ── the callers still call it by this path ───────────────────────────────────

echo "the callers still name bin/jobman, not the module"
# A cron line naming a packaged module would freeze that name in /etc/cron.d on
# every provisioned node forever — there is no cron-convergence plane. The shim
# lives in the clone update.sh refreshes on every deploy, so it stays fixable.
assert_has "$REPO/aws/update.sh" "\./bin/jobman stop" "update.sh stops the engine through the shim"

# ── result ───────────────────────────────────────────────────────────────────

echo
echo "test_jobman_sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

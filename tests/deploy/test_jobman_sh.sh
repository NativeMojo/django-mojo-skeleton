#!/bin/bash
# Harness for `bin/jobman status` (maestro item #1600).
#
# Runs the REAL script from a throwaway PROJECT_ROOT — jobman derives its root
# from $BASH_SOURCE and has no env seam, so isolation comes from copying it into
# $TMP/proj/bin and letting var/pids land in the temp tree. `pgrep` and `ps` are
# stubbed on PATH so every process state is a fixture rather than a real fork.
#
# The property under test: "extra instances detected" must mean strictly more
# than the one instance jobman manages. On a healthy node the pidfile's own PID
# is always in the pgrep result, and the pre-fix script reported it as an extra
# instance of itself. Case 1 is that regression.
#
# Assertions are on stdout because jobman's contract IS its stdout.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
STUB="$TMP/stubs"
CTL="$TMP/ctl"
OUT="$TMP/out.txt"
export STUBCTL="$CTL"

PASS=0
FAIL=0
RC=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got: $1, want: $2)"; fi
}
# exact whole-line match — a line with an extra PID appended does NOT count
assert_line() {
    if grep -qxF "$1" "$OUT" 2>/dev/null; then ok "$2"; else fail "$2 (no exact line '$1')"; fi
}
assert_out() {
    if grep -qF "$1" "$OUT" 2>/dev/null; then ok "$2"; else fail "$2 (no '$1' in output)"; fi
}
assert_not_out() {
    if grep -qF "$1" "$OUT" 2>/dev/null; then fail "$2 ('$1' present)"; else ok "$2"; fi
}
assert_line_count() {
    local got
    got="$(wc -l < "$OUT" | tr -d ' ')"
    assert_eq "$got" "$1" "$2"
}

# ── fixtures ─────────────────────────────────────────────────────────────────

# write_pids <file> <space-separated PIDs, possibly empty>  — one PID per line
write_pids() {
    local file="$1" pids="$2" p
    : > "$file"
    for p in $pids; do echo "$p" >> "$file"; done
}

set_alive()     { write_pids "$CTL/alive.txt" "$1"; }            # PIDs `ps -p` reports live
set_pgrep()     { write_pids "$CTL/pgrep_$1.txt" "$2"; }         # PIDs pgrep -f returns
write_pidfile() { mkdir -p "$PROJ/var/pids"; echo "$2" > "$PROJ/var/pids/job_$1.pid"; }

setup_case() {
    rm -rf "$PROJ" "$STUB" "$CTL"
    mkdir -p "$PROJ/bin" "$STUB" "$CTL"
    cp "$REPO/bin/jobman" "$PROJ/bin/jobman"
    chmod +x "$PROJ/bin/jobman"

    # default fixture: nothing running anywhere, no pidfiles
    set_alive ""
    set_pgrep engine ""
    set_pgrep scheduler ""

    # pgrep stub — jobman's pattern names the component, so dispatch on argv.
    # Real pgrep exits 1 with no output when nothing matches; so does this.
    cat > "$STUB/pgrep" <<'EOF'
#!/bin/bash
case "$*" in
  *scheduler*) f="$STUBCTL/pgrep_scheduler.txt" ;;
  *engine*)    f="$STUBCTL/pgrep_engine.txt" ;;
  *)           exit 1 ;;
esac
[ -s "$f" ] || exit 1
cat "$f"
EOF
    chmod +x "$STUB/pgrep"

    # ps stub — `ps -p <pid>` succeeds only for a PID the fixture declared alive
    cat > "$STUB/ps" <<'EOF'
#!/bin/bash
pid=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-p" ]; then pid="${2:-}"; break; fi
  shift
done
[ -n "$pid" ] || exit 1
grep -qxF "$pid" "$STUBCTL/alive.txt" 2>/dev/null
EOF
    chmod +x "$STUB/ps"
}

run_status() { # [component]
    ( cd "$TMP" && PATH="$STUB:$PATH" bash "$PROJ/bin/jobman" status "$@" ) > "$OUT" 2>&1
    RC=$?
}

# ── tests ────────────────────────────────────────────────────────────────────

echo "jobman status: a healthy engine is not an extra instance of itself (regression)"
setup_case
write_pidfile engine 1000
set_alive "1000"
set_pgrep engine "1000"
run_status engine
assert_eq "$RC" 0 "healthy status exits 0"
assert_line "Engine running (PID 1000)" "healthy engine reports running"
assert_not_out "extra instances" "the managed PID is never reported as an extra"
assert_not_out "unmanaged instances" "no unmanaged line while the pidfile is live"
assert_line_count 1 "healthy engine prints exactly one line"

echo "jobman status: one genuine duplicate is reported, without the managed PID"
setup_case
write_pidfile engine 1000
set_alive "1000 2000"
set_pgrep engine "1000 2000"
run_status engine
assert_line "Engine running (PID 1000)" "status line still names the managed PID"
assert_line "Engine extra instances detected: 2000" "only the duplicate is listed"

echo "jobman status: two genuine duplicates stay on one space-joined line"
setup_case
write_pidfile engine 1000
set_alive "1000 2000 3000"
set_pgrep engine "1000 2000 3000"
run_status engine
assert_line "Engine running (PID 1000)" "status line still names the managed PID"
assert_line "Engine extra instances detected: 2000 3000" "both duplicates on a single line"

echo "jobman status: a stale pidfile with nothing running is silent"
setup_case
write_pidfile engine 1000
set_alive ""
set_pgrep engine ""
run_status engine
assert_line "Engine not running (stale PID file: $PROJ/var/pids/job_engine.pid)" "stale line unchanged"
assert_not_out "extra instances" "no extra line with nothing running"
assert_not_out "unmanaged instances" "no unmanaged line with nothing running"

echo "jobman status: a stale pidfile plus a live process reports it as unmanaged"
setup_case
write_pidfile engine 1000
set_alive "2000"
set_pgrep engine "2000"
run_status engine
assert_line "Engine not running (stale PID file: $PROJ/var/pids/job_engine.pid)" "stale line unchanged"
assert_line "Engine unmanaged instances detected: 2000" "the live process is reported as unmanaged"
assert_not_out "extra instances" "nothing is 'extra' without a managed instance"

echo "jobman status: two unmanaged processes stay on one space-joined line"
setup_case
write_pidfile engine 1000
set_alive "2000 3000"
set_pgrep engine "2000 3000"
run_status engine
assert_line "Engine not running (stale PID file: $PROJ/var/pids/job_engine.pid)" "stale line unchanged"
assert_line "Engine unmanaged instances detected: 2000 3000" "both unmanaged PIDs on a single line"

echo "jobman status: nothing running at all prints one line"
setup_case
run_status engine
assert_eq "$RC" 0 "not-running status exits 0"
assert_line "Engine not running" "not-running line unchanged"
assert_line_count 1 "not-running prints exactly one line"

echo "jobman status: no pidfile but a live process reports it as unmanaged"
setup_case
set_alive "4000"
set_pgrep engine "4000"
run_status engine
assert_line "Engine not running" "not-running line unchanged"
assert_line "Engine unmanaged instances detected: 4000" "the untracked process is reported"

echo "jobman status: a bare healthy run prints exactly two lines, one per component"
setup_case
write_pidfile engine 1000
write_pidfile scheduler 1100
set_alive "1000 1100"
set_pgrep engine "1000"
set_pgrep scheduler "1100"
run_status
assert_eq "$RC" 0 "bare status exits 0"
assert_line_count 2 "a healthy node prints exactly two lines"
assert_line "Engine running (PID 1000)" "engine line present"
assert_line "Scheduler running (PID 1100)" "scheduler line present"

echo "jobman status: the scheduler gets the same subtraction as the engine"
setup_case
write_pidfile scheduler 1100
set_alive "1100 2200"
set_pgrep scheduler "1100 2200"
run_status scheduler
assert_line "Scheduler running (PID 1100)" "scheduler status line"
assert_line "Scheduler extra instances detected: 2200" "only the scheduler duplicate is listed"

# ── result ───────────────────────────────────────────────────────────────────

echo
echo "test_jobman_sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

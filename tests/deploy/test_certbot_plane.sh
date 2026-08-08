#!/bin/bash
# Harness for the certificate plane (maestro item #1599).
#
# Covers the four defects that only surface on a real two-node fleet: the
# EXDEV staging bug that made every replica pull fail forever, certbot living
# in the app's Python, the cert-plane keys landing where nothing reads them,
# and ungated renewal on replicas.
#
# aws/certbot_sync.py runs for real here — boto3 is only imported past the
# config gate, so the gating paths need no AWS and no network. Every run sets
# CERTBOT_SYNC_LOCK into the temp dir: acquire_lock() opens the path for
# writing, and the production default (/var/run/...) needs root. PYTHONPATH
# also points at a poisoned boto3/botocore, so any path that imports them when
# it shouldn't fails loudly instead of quietly passing.
#
# The three provisioning scripts cannot be executed (dnf, alternatives, sshd
# -t), so their guarantees are asserted against their text.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/stubs"
POISON="$TMP/poison"
OUT="$TMP/out.log"
export CALLLOG="$TMP/calls.log"

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
assert_in_log()     { assert_has "$CALLLOG" "$1" "$2"; }
assert_not_in_log() { assert_lacks "$CALLLOG" "$1" "$2"; }

setup_env() {
    rm -rf "$STUB" "$POISON"
    mkdir -p "$STUB" "$POISON"
    : > "$CALLLOG"

    cat > "$STUB/certbot" <<'EOF'
#!/bin/bash
echo "CMD certbot $*" >> "$CALLLOG"
exit 0
EOF
    chmod +x "$STUB/certbot"

    # Importing either of these is itself the failure — the gating paths under
    # test must return before any S3 work.
    echo 'raise ImportError("boto3 must not be imported on this path")'   > "$POISON/boto3.py"
    echo 'raise ImportError("botocore must not be imported on this path")' > "$POISON/botocore.py"
}

run_sync() { # conf args...
    local conf="$1"; shift
    ( cd "$REPO" && CERTBOT_SYNC_LOCK="$TMP/certbot_sync.lock" \
        PATH="$STUB:$PATH" PYTHONPATH="$POISON" \
        python3 aws/certbot_sync.py --config "$conf" --verbose "$@" ) > "$OUT" 2>&1
}

BOOTSTRAP="$REPO/aws/ec2_bootstrap.sh"
WWW="$REPO/aws/ec2_www.sh"
DEPLOY_SH="$REPO/aws/ec2_deploy.sh"
SYNC_PY="$REPO/aws/certbot_sync.py"
DEPLOY_PY="$REPO/aws/deploy.py"

# ── Group A: staging invariant (the EXDEV defect) ────────────────────────────

echo "certbot_sync.py: staging shares a filesystem with the destination"
( cd "$REPO" && python3 - <<'PY' > "$TMP/group_a.out" 2>&1
import importlib.util
spec = importlib.util.spec_from_file_location("cs", "aws/certbot_sync.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("LETSENCRYPT_DIR=%s" % mod.LETSENCRYPT_DIR)
print("LINEAGE=%s" % mod.lineage_dir("example.com"))
print("ANCESTOR=%s" % mod.lineage_dir("example.com").startswith(mod.LETSENCRYPT_DIR + "/"))
PY
)
assert_has "$TMP/group_a.out" "^LETSENCRYPT_DIR=/etc/letsencrypt$" "LETSENCRYPT_DIR is /etc/letsencrypt"
assert_has "$TMP/group_a.out" "^LINEAGE=/etc/letsencrypt/live/example.com$" "lineage_dir is derived from it"
assert_has "$TMP/group_a.out" "^ANCESTOR=True$" "staging root is an ancestor of the destination (no cross-device rename)"
assert_lacks "$SYNC_PY" 'dir="/tmp"' "nothing stages in /tmp any more"

# ── Group B: --renew gating (the co-install and replica defects) ─────────────

echo "certbot_sync.py --renew: an unconfigured box still renews itself"
setup_env
run_sync "$TMP/unconfigured.conf" --renew --dry-run; rc=$?
assert_eq "$rc" 0 "unconfigured --renew exits 0"
assert_has "$OUT" "would run: $STUB/certbot renew" "heartbeat logged, and find_certbot() honors PATH"
assert_lacks "$OUT" "replica node" "an unconfigured box is never treated as a replica"

setup_env
run_sync "$TMP/unconfigured.conf" --renew; rc=$?
assert_eq "$rc" 0 "unconfigured --renew (for real) exits 0"
assert_in_log "CMD certbot renew --post-hook systemctl reload nginx --quiet" "certbot invoked with the reload post-hook"
assert_has "$OUT" "renew ok (single-node box" "success is logged, not silent"

echo "certbot_sync.py --renew: a configured replica never runs certbot"
setup_env
printf 'AWS_CERT_BUCKET = "acme-certs"\nLOAD_BALANCER_DOMAIN = "acme.com"\nPRIMARY_BALANCER_HOST = "not-this-host"\n' \
    > "$TMP/replica.conf"
run_sync "$TMP/replica.conf" --renew; rc=$?
assert_eq "$rc" 0 "replica --renew exits 0"
assert_has "$OUT" "replica node — renewal is the primary's job, skipping" "the skip is logged"
assert_not_in_log "certbot" "certbot NEVER runs on a replica (a synced lineage would be corrupted)"

echo "certbot_sync.py --renew: configured with no PRIMARY_BALANCER_HOST refuses"
setup_env
printf 'AWS_CERT_BUCKET = "acme-certs"\nLOAD_BALANCER_DOMAIN = "acme.com"\n' > "$TMP/noprimary.conf"
run_sync "$TMP/noprimary.conf" --renew; rc=$?
assert_eq "$rc" 1 "refusing to guess which node renews exits 1"
assert_has "$OUT" "refusing to guess which node renews" "the refusal is logged"
assert_not_in_log "certbot" "nothing renews while the role is ambiguous"

echo "certbot_sync.py: the sync path is still dormant when unconfigured"
setup_env
run_sync "$TMP/unconfigured.conf"; rc=$?
assert_eq "$rc" 0 "a bare run on an unconfigured box exits 0"
assert_not_in_log "certbot" "and runs nothing"

# ── Group C: deploy.py writes the keys where certbot_sync.py reads them ──────

echo "deploy.py: the cert-plane keys land in var/django.conf's managed block"
REAL_CONF="$REPO/var/django.conf"
real_conf_before="absent"
[ -f "$REAL_CONF" ] && real_conf_before="$(cksum < "$REAL_CONF")"

( cd "$REPO" && CONF_DIR="$TMP/confdir" python3 - <<'PY' > "$TMP/group_c.out" 2>&1
import importlib.util, os

CERT_KEYS = ("LOAD_BALANCER_DOMAIN", "PRIMARY_BALANCER_HOST", "AWS_CERT_BUCKET")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


deploy = load("aws/deploy.py", "deploy")
sync = load("aws/certbot_sync.py", "cs")

var_dir = os.environ["CONF_DIR"]
os.makedirs(var_dir, exist_ok=True)
conf_path = os.path.join(var_dir, "django.conf")

# Both are computed at import time from the real checkout — override BOTH or
# this writes into it.
deploy.VAR_DIR = var_dir
deploy.DJANGO_CONF = conf_path
deploy.PROJECT = "acme"
deploy.SES_DOMAIN = "acme.com"


def block_lines():
    lines = open(conf_path).read().splitlines()
    start = lines.index(deploy.DJANGO_CONF_BEGIN)
    end = lines.index(deploy.DJANGO_CONF_END)
    return lines[start:end]


def write(count):
    deploy.EC2_COUNT = count
    deploy.write_django_conf("us-east-1", "db.local", "cache.local")


write(2)
inside = block_lines()
print("multi_keys_in_block=%d" % sum(
    1 for k in CERT_KEYS if any(line.startswith('%s = "' % k) for line in inside)))
print("multi_primary=%s" % sync.read_config(conf_path).get("PRIMARY_BALANCER_HOST"))
print("expected_primary=%s" % deploy._node_hostname(1))

# What deploy.py writes is what certbot_sync.py reads — end to end.
parsed = sync.read_config(conf_path)
print("roundtrip=%s" % ",".join(parsed.get(k, "MISSING") for k in CERT_KEYS))

# Re-running must replace the managed block, not append a second copy.
write(2)
body = open(conf_path).read()
print("idempotent_max=%d" % max(body.count('%s = "' % k) for k in CERT_KEYS))

write(1)
print("single_keys=%d" % sum(1 for k in CERT_KEYS if k in open(conf_path).read()))
PY
)
assert_has "$TMP/group_c.out" "^multi_keys_in_block=3$" "all three keys land inside the managed block on a fleet"
assert_has "$TMP/group_c.out" "^multi_primary=acme-node1$" "PRIMARY_BALANCER_HOST is node 1"
assert_has "$TMP/group_c.out" "^expected_primary=acme-node1$" "and matches _node_hostname(1)"
assert_has "$TMP/group_c.out" "^roundtrip=acme.com,acme-node1,acme-certs$" "certbot_sync.read_config() parses back exactly what deploy.py wrote"
assert_has "$TMP/group_c.out" "^idempotent_max=1$" "re-running writes each key exactly once"
assert_has "$TMP/group_c.out" "^single_keys=0$" "a single-node conf gets none of them (sync stays dormant)"

real_conf_after="absent"
[ -f "$REAL_CONF" ] && real_conf_after="$(cksum < "$REAL_CONF")"
assert_eq "$real_conf_after" "$real_conf_before" "the real checkout's var/django.conf was never touched"

# ── Group D: provisioning-script content ─────────────────────────────────────

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

echo "crons: every certbot cron can find certbot, and only the primary renews"
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
assert_has "$DEPLOY_SH" "certbot_sync.py --renew" "ec2_deploy.sh's 1_certbot runs the role-aware renew"
assert_lacks "$DEPLOY_SH" "root certbot renew" "ec2_deploy.sh installs no plain renew cron"
assert_has "$BOOTSTRAP" "root certbot renew" "the pre-clone bootstrap keeps its own plain renew (it has no /opt/api yet)"
assert_has "$WWW" "root certbot renew" "so does its curl-one-liner twin"

echo "ec2_deploy.sh: fleet instructions, and the config it actually reads"
assert_has "$DEPLOY_SH" "certonly --webroot -w /var/www/certbot" "the primary branch issues via the webroot"
# The branch may still MENTION --nginx (it warns against it); what must be
# gone is the instruction to run it.
primary_branch="$(sed -n '/this IS the primary node/,/^    else$/p' "$DEPLOY_SH")"
if echo "$primary_branch" | grep -q -- "certbot --nginx"; then
    fail "the primary branch still tells the operator to run certbot --nginx"
else
    ok "the primary branch no longer tells the operator to run certbot --nginx"
fi
assert_has "$DEPLOY_SH" "var/django.conf\" 2>/dev/null" "PRIMARY_BALANCER_HOST is read from django.conf, not ops.json"
assert_lacks "$DEPLOY_SH" "ops.json\" 2>/dev/null" "and no longer from var/ops.json"

echo "nginx: the vhosts stay self-contained so replicas can serve them"
# A real include DIRECTIVE, not a comment warning against one (app.conf has
# the latter on purpose).
if grep -rqE '^[[:space:]]*include[[:space:]][^;]*options-ssl-nginx\.conf' "$REPO/aws/nginx/"; then
    fail "an nginx config includes options-ssl-nginx.conf (breaks nginx -t on replicas)"
else
    ok "no nginx config includes options-ssl-nginx.conf"
fi
assert_has "$REPO/aws/nginx/conf.d/app.conf" "certonly --webroot" "app.conf documents the fleet-safe issuance command"

echo "deploy.py: Phase 3 delivers the conf to the fleet"
assert_has "$DEPLOY_PY" "a BARE full run, not --step ec2/nlb" "the documented scale-out is a full run"
assert_has "$DEPLOY_PY" "BARE full run — every step is get-or-create" "and the bake-ami completion message says the same"

# ── Group E: syntax gates ────────────────────────────────────────────────────

echo "syntax"
for f in "$BOOTSTRAP" "$WWW" "$DEPLOY_SH"; do
    bash -n "$f" 2>"$TMP/syntax.err"
    assert_eq "$?" 0 "$(basename "$f") parses"
done
( cd "$REPO" && python3 -m py_compile aws/certbot_sync.py aws/deploy.py ) 2>"$TMP/syntax.err"
assert_eq "$?" 0 "certbot_sync.py and deploy.py compile"

# ── result ───────────────────────────────────────────────────────────────────

echo
echo "test_certbot_plane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

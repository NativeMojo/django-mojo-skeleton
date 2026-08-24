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
assert_fixed() { # file literal label
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3 (no literal '$2' in $(basename "$1"))"; fi
}
assert_lacks() { # file pattern label
    if grep -q -- "$2" "$1" 2>/dev/null; then fail "$3 ('$2' present in $(basename "$1"))"; else ok "$3"; fi
}

BOOTSTRAP="$REPO/aws/ec2_bootstrap.sh"
WWW="$REPO/aws/ec2_www.sh"
DEPLOY_SH="$REPO/aws/ec2_deploy.sh"
DEPLOY_PY="$REPO/aws/deploy.py"
SUDOERS="$REPO/aws/nginx/sudoers.d/mojo-edge"
# The systemd units are django-mojo's, not this project's. This repo used to
# keep its own copies under aws/nginx/systemd/, which `mojo.deploy render`
# ignored as undeclared collisions — the framework template wins — so the
# copies were inert while looking authoritative. They are gone; assert against
# what the node actually installs.
#
# Resolved through whichever interpreter can actually see django-mojo: a node
# has it on the system python, a developer checkout has it in the uv
# environment, and a test that silently skipped when neither worked would be
# worse than one that fails loudly.
find_unit_dir() {
    local expr='import os, mojo.deploy; print(os.path.join(os.path.dirname(mojo.deploy.__file__), "templates", "systemd"))'
    local out
    for py in "python3" ".venv/bin/python"; do
        out="$("$py" -c "$expr" 2>/dev/null)" && [ -n "$out" ] && { echo "$out"; return 0; }
    done
    out="$(cd "$REPO" && uv run --quiet python -c "$expr" 2>/dev/null)" \
        && [ -n "$out" ] && { echo "$out"; return 0; }
    return 1
}
UNIT_DIR="$(find_unit_dir)" || fail "django-mojo is not importable by any interpreter — cannot audit the systemd units it ships"
SERVICE="$UNIT_DIR/config-sync.service"
TIMER="$UNIT_DIR/config-sync.timer"
APP_CONF="$REPO/aws/nginx/conf.d/app.conf"
MOJO_CONF="$REPO/aws/nginx/conf.d/mojo.conf"
NGINX_CONF="$REPO/aws/nginx/nginx.conf"
PROD_SETTINGS="$REPO/config/settings/prod/__init__.py"
TF_NODES="$REPO/aws/terraform/modules/nodes/main.tf"
TF_STAGING="$REPO/aws/terraform/envs/example.staging.tfvars"
TF_PROD="$REPO/aws/terraform/envs/example.prod.tfvars"

# Remapping /usr/bin/python3 to the application interpreter must not break
# distro tools. AWS CLI's AL2023 launcher includes both whitespace after #!
# and the -s interpreter flag, so an exact '#!/usr/bin/python3' matcher misses
# it even though it depends on the distro's Python 3.9 awscli package.
echo "bootstraps: every distro-python shebang form is pinned before remapping"
for f in "$BOOTSTRAP" "$WWW"; do
    n="$(basename "$f")"
    assert_fixed "$f" "grep -rlZ --binary-files=without-match -E '^#![[:space:]]*/usr/bin/python3([[:space:]]|$)'" \
        "$n finds shebangs with whitespace and interpreter arguments"
    assert_fixed "$f" "sed -i -E '1s|^#![[:space:]]*/usr/bin/python3([[:space:]].*)?$|#!/usr/bin/python3.9\\1|'" \
        "$n preserves interpreter arguments while pinning Python 3.9"
done
pin_expr='1s|^#![[:space:]]*/usr/bin/python3([[:space:]].*)?$|#!/usr/bin/python3.9\1|'
assert_eq "$(printf '#! /usr/bin/python3 -s\n' | sed -E "$pin_expr")" \
    "#!/usr/bin/python3.9 -s" "the AWS CLI shebang is pinned and keeps -s"
assert_eq "$(printf '#!/usr/bin/python3\n' | sed -E "$pin_expr")" \
    "#!/usr/bin/python3.9" "the bare distro shebang is still pinned"

echo "terraform nodes: every instance receives the standard AWS setup role"
assert_has "$TF_NODES" '^resource "aws_iam_role" "node"' \
    "the node role is managed with the fleet"
assert_has "$TF_NODES" '^resource "aws_iam_role_policy" "node_setup"' \
    "the setup permissions are managed with the fleet"
assert_has "$TF_NODES" 'iam_instance_profile.*aws_iam_instance_profile.node.name' \
    "every EC2 node receives the instance profile"
for service in route53domains s3 ec2 rds elasticache iam cloudwatch sns ses guardduty events; do
    assert_has "$TF_NODES" "\"${service}:\\*\"" \
        "the setup role includes ${service} provisioning"
done
assert_fixed "$TF_NODES" 'data "aws_partition" "current"' \
    "the AMI parameter ARN derives the active AWS partition"
assert_fixed "$TF_NODES" 'data "aws_region" "current"' \
    "the AMI parameter ARN derives the active AWS region"
assert_fixed "$TF_NODES" 'Sid      = "DjangoMojoAmiParameter"' \
    "the AMI parameter read is isolated in its own policy statement"
assert_fixed "$TF_NODES" 'Action   = ["ssm:GetParameter"]' \
    "the AMI parameter grant is read-only and exact"
assert_fixed "$TF_NODES" 'Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"' \
    "the AMI parameter grant is exact within the active region"
assert_lacks "$TF_NODES" '"ssm:\*"' \
    "the node role has no wildcard SSM permission"
assert_fixed "$TF_STAGING" 'region  = "us-west-2"' \
    "the dynamic policy covers the shipped staging region"
assert_fixed "$TF_PROD" 'region  = "us-east-1"' \
    "the dynamic policy covers the shipped production region"

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
assert_fixed "$DEPLOY_SH" 'python3 -m mojo.deploy.node_setup --root "$PROJ_PATH" --units-dir "${PROJ_PATH}/var/deploy/systemd"' \
    "ec2_deploy.sh installs the systemd contract rendered by stage 1"
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

echo "nginx: the edge include ships whole, and is inert until a generation exists"
# BOTH globs, and http.d first. Including only conf.d stages the vhosts and
# leaves every `proxy_pass http://edge_up_N` naming an upstream nginx never
# read, and every `if ($edge_block_ip)` naming a map that does not exist —
# `nginx -t` fails with "host not found in upstream", which reads like DNS.
assert_has "$MOJO_CONF" "^include /opt/api/var/edge/current/http\.d/\*\.conf;$" \
    "conf.d/mojo.conf includes the rendered http base and upstreams"
assert_has "$MOJO_CONF" "^include /opt/api/var/edge/current/conf\.d/\*\.conf;$" \
    "conf.d/mojo.conf includes the rendered vhosts"
http_line="$(grep -n '^include .*http\.d' "$MOJO_CONF" | cut -d: -f1)"
conf_line="$(grep -n '^include .*edge/current/conf\.d' "$MOJO_CONF" | cut -d: -f1)"
if [ -n "$http_line" ] && [ -n "$conf_line" ] && [ "$http_line" -lt "$conf_line" ]; then
    ok "the base and upstreams are included before the vhosts that use them"
else
    fail "http.d must be included before conf.d (got ${http_line:-none} and ${conf_line:-none})"
fi

echo "nginx: the bootstrap owns only what must exist before a generation does"
# The rendered base declares these; a second copy at http level is an [emerg].
# Directives only — the file EXPLAINS the split in its header, so a plain grep
# would match the prose describing what it deliberately does not declare.
grep -v '^[[:space:]]*#' "$NGINX_CONF" > "$TMP/nginx.directives"
for directive in "include.*mime\.types" "log_format" "access_log" "\$loggable"; do
    assert_lacks "$TMP/nginx.directives" "$directive" \
        "the rendered http base owns ${directive}, not the bootstrap"
done
# And the one map that must stay: app.conf proxies through asgi.inc, which
# references it, and a fresh box starts nginx before it can ever converge.
assert_has "$NGINX_CONF" "map \$http_upgrade \$connection_upgrade" \
    "the bootstrap keeps \$connection_upgrade so day 0 works"

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

echo "settings: the opt-in is one edit, and the retired gate stays retired"
assert_has "$PROD_SETTINGS" "^EDGE_CONVERGE_ENABLED = False$" "convergence ships off"
# EDGE_RESERVED_SERVER_NAMES was retired upstream (edge migration 0005) —
# an assignment reappearing here would be dead config masquerading as a gate.
assert_lacks "$PROD_SETTINGS" "^EDGE_RESERVED_SERVER_NAMES" \
    "the retired EDGE_RESERVED_SERVER_NAMES setting is not assigned"
assert_has "$PROD_SETTINGS" "0005_remove_vhost_claims_reserved" \
    "with the retirement note naming the migration that dropped it"

echo "deploy.py: the KSMSecrets KMS key is provisioned and wired into the conf"
# dnsman's AcmeAccount/Certificate are KSMSecrets models — no KMS_KEY_ID means
# the certificate plane dies with RuntimeError on first use.
assert_has "$DEPLOY_PY" "def setup_kms" "setup_kms exists"
assert_has "$DEPLOY_PY" '"kms", "rds"' "kms runs as a step before the conf is written"
assert_fixed "$DEPLOY_PY" "KMS_KEY_ID = " "KMS_KEY_ID reaches the managed conf block"

# ── Group F2: one provisioner owns one environment ───────────────────────────
#
# The skeleton ships three things that can create AWS resources: the admin
# portal (the owner on a managed installation), aws/deploy.py (first stand-up
# only) and the OpenTofu root (INFRASTRUCTURE_MODE = "external" only). Nothing
# in code can stop an operator running two of them, so what is asserted here is
# that the skeleton SAYS which one owns an environment, and that the one place
# the duplication is silent — the alarm plane — ships off.

TF_VARS="$REPO/aws/terraform/variables.tf"
TF_MAIN="$REPO/aws/terraform/main.tf"
TF_OUTPUTS="$REPO/aws/terraform/outputs.tf"
TF_README="$REPO/aws/terraform/README.md"
OBS_MAIN="$REPO/aws/terraform/modules/observability/main.tf"
OBS_VARS="$REPO/aws/terraform/modules/observability/variables.tf"
PROD_TFVARS="$REPO/aws/terraform/envs/example.prod.tfvars"
STAGING_TFVARS="$REPO/aws/terraform/envs/example.staging.tfvars"
AWS_README="$REPO/aws/README.md"

echo "terraform: the alarm plane is a flag, and it defaults to this root owning it"
assert_fixed "$TF_VARS" 'variable "enable_alarms" {' "the root declares enable_alarms"
awk '/^variable "enable_alarms" \{/{f=1} f{print} f&&/^\}/{exit}' "$TF_VARS" > "$TMP/enable_alarms"
assert_has "$TMP/enable_alarms" "^  type        = bool$" "enable_alarms is a bool"
assert_has "$TMP/enable_alarms" "^  default     = true$" \
    "and defaults true — this root's own behaviour, for the external-mode installation it is written for"
assert_has "$TF_MAIN" "^  enable_alarms      = var.enable_alarms$" \
    "the root passes it into the observability module"
assert_fixed "$OBS_VARS" 'variable "enable_alarms" {' "the module accepts it"
awk '/^variable "enable_alarms" \{/{f=1} f{print} f&&/^\}/{exit}' "$OBS_VARS" > "$TMP/mod_enable_alarms"
assert_lacks "$TMP/mod_enable_alarms" "^ *default *=" "with no default in the module — the root always passes it"

echo "terraform: both shipped environments leave the alarms to the admin portal"
for f in "$PROD_TFVARS" "$STAGING_TFVARS"; do
    assert_has "$f" "^enable_alarms *= false$" "$(basename "$f") sets enable_alarms = false"
    assert_fixed "$f" 'INFRASTRUCTURE_MODE' "$(basename "$f") says which mode it describes"
done

echo "capacity defaults: paid data-plane redundancy is explicit, never implied"
assert_eq "$(grep -c '^      db_reader_count = 0$' "$TF_MAIN")" "4" \
    "every OpenTofu size preset defaults to one Aurora writer"
assert_eq "$(grep -c '^      cache_replicas  = 0$' "$TF_MAIN")" "4" \
    "every OpenTofu size preset defaults to one cache node"
assert_has "$PROD_TFVARS" '^db_reader_count = 0$' \
    "the production example makes its writer-only choice explicit"
assert_has "$PROD_TFVARS" '^cache_replicas  = 0$' \
    "the production example makes its single-cache choice explicit"
python3 - "$DEPLOY_PY" <<'PY'
import ast
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
tiers = None
for node in tree.body:
    if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "TIER_DEFAULTS"
            for target in node.targets):
        tiers = ast.literal_eval(node.value)
        break
assert tiers, "TIER_DEFAULTS is missing"
assert all(row["DB_READER_COUNT"] == 0 for row in tiers.values()), tiers
assert all(row["CACHE_NUM_NODES"] == 1 for row in tiers.values()), tiers
PY
assert_eq "$?" "0" \
    "every bootstrap tier defaults to one Aurora writer and one cache node"

echo "observability: every alarm and the topic are behind the flag"
assert_lacks "$OBS_MAIN" "aws_sns_topic\.alarms\.arn" \
    "no unindexed topic reference survives the count"
assert_has "$OBS_MAIN" "^  count = var.enable_alarms ? 1 : 0$" "the topic is counted off"
assert_has "$OBS_MAIN" "^  count = var.enable_alarms ? length(var.node_instance_ids) : 0$" \
    "so are the per-node alarms"
assert_fixed "$OBS_MAIN" "for_each = var.enable_alarms && var.enable_lb_alarms ? {" \
    "and the target-health alarms, without losing the plan-time key set"
moved="$(grep -c '^moved {' "$OBS_MAIN")"
assert_eq "$moved" "6" "the six newly-counted resources carry moved blocks (no destroy/recreate on upgrade)"
assert_fixed "$OBS_MAIN" "moved {" "the moved blocks are present at all"

echo "observability: the audit trail is NOT part of the alarm flag"
# Nothing in the portal creates CloudTrail, GuardDuty or the log groups — it
# only audits them — so they stay this root's whoever owns the alarms.
assert_has "$OBS_MAIN" "^  count = var.enable_cloudtrail ? 1 : 0$" "cloudtrail keeps its own gate"
assert_has "$OBS_MAIN" "^  count = var.enable_guardduty ? 1 : 0$" "guardduty keeps its own gate"
assert_fixed "$OBS_MAIN" 'for_each = toset(["nginx-access", "nginx-error", "app"])' \
    "and the log groups are created unconditionally"

echo "terraform: the conf fragment writes no alarm topic it does not own"
assert_fixed "$TF_OUTPUTS" '%{if var.enable_alarms~}' "the fragment is conditional on enable_alarms"
assert_fixed "$TF_OUTPUTS" 'the admin portal owns the alarms' \
    "and says who owns the key when it is omitted"

echo "docs: the tofu root states which installation it is for"
assert_fixed "$TF_README" "## Who owns this environment" "the README opens with the ownership section"
assert_fixed "$TF_README" 'INFRASTRUCTURE_MODE = "external"' "and names the mode that selects this root"
assert_fixed "$TF_README" "Do not run both" "with the do-not-run-both warning"
# Contradicted by the same file and by modules/nodes/main.tf, which creates
# aws_iam_role.node with the django-mojo-setup inline policy.
assert_lacks "$TF_README" "No IAM role is attached to the nodes" \
    "the false no-instance-profile claim is gone"
assert_fixed "$AWS_README" "External-mode installations only" \
    "the operator guide files the tofu path under external mode"

echo "deploy.py: it says it is a bootstrap, and points at the ownership section"
assert_fixed "$DEPLOY_PY" "This is a FIRST STAND-UP BOOTSTRAP" \
    "the docstring leads with what this script is"
assert_fixed "$DEPLOY_PY" 'aws/terraform/README.md, "Who owns this environment"' \
    "and points at the ownership section"
assert_fixed "$DEPLOY_PY" "first stand-up bootstrap, not the owner of a running environment." \
    "the deploy confirm warns before anything is created"
# The provisioning steps stay: removing them is deferred, and a silent trim
# here would strand a first stand-up with no way to create anything.
assert_fixed "$DEPLOY_PY" '"ec2-setup", "ses", "github-webhook", "verify"' \
    "the provisioning steps are untouched"

echo "settings: the mode selector ships commented out, and fails closed when set"
assert_has "$PROD_SETTINGS" '^# INFRASTRUCTURE_MODE = "external"$' \
    "INFRASTRUCTURE_MODE is documented but not set"
assert_lacks "$PROD_SETTINGS" "^INFRASTRUCTURE_MODE" \
    "so a fresh clone is managed — the portal owns the estate"

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

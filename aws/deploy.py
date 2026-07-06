#!/usr/bin/env python
"""
AWS Infrastructure Setup

var/deploy.json is the single source of truth for everything this script
tracks. Build it either way:
  - Interactively: `python aws/deploy.py --init` prompts for domain, region,
    and a volume tier (low/medium/high), and writes the file.
  - By hand: copy aws/deploy.example.json to var/deploy.json and edit it.
    Only DOMAIN is required — everything else falls back to volume-tier
    defaults (below), and DB_PASSWORD/SYSTEM_UPDATE_TOKEN get generated and
    persisted automatically on first load if you don't set them yourself.
    Add any of these keys to override a specific value: PROJECT, REGION,
    VOLUME, DB_NAME, DB_USER, DB_PASSWORD, SYSTEM_UPDATE_TOKEN, AWS_KEY,
    AWS_SECRET, INSTANCE_TYPE, EC2_COUNT, DB_INSTANCE_CLASS, DB_READER_COUNT,
    CACHE_NODE_TYPE, CACHE_NUM_NODES, USE_NLB, EMAIL_FROM, CUSTOM_AMI_ID,
    PEM_PATH (see pem_file_path() — defaults to aws/{project}-{region}.pem,
    override for setups with their own key storage convention, e.g.
    "~/.ssh/idents/{project}.pem").

The GitHub repo is never asked for or stored by default — it's auto-detected
from `git remote get-url origin` each time it's needed (see
_detect_github_repo()), since this script is always run from inside the app
repo it's deploying. Set GITHUB_REPO in var/deploy.json only to override
(e.g. deploying a fork under a different name).

AWS_KEY/AWS_SECRET/AWS_REGION for deploy.py's OWN boto3 calls live in
var/deploy.json (prompted by the wizard, masked when typed) — NOT
var/django.conf. A local dev setup might run against local Postgres/Redis
with no AWS access at all and shouldn't need real AWS creds just to satisfy
this script. Once you actually provision something, write_django_conf()
copies them into var/django.conf's managed block for you, since the
*deployed app* does need them as real Django settings (S3/SES, etc) — that
file's format is fixed by the django-mojo framework, not by us, so it can't
be folded into deploy.json itself; see write_django_conf().

Volume tiers (edit var/deploy.json to override any value):
  low     1x t3.small EC2, Aurora db.t3.medium (writer only), Valkey cache.t4g.small x1
  medium  1x t3.medium EC2, Aurora db.t3.medium (1 writer + 1 reader), Valkey cache.t3.medium x2
  high    2x t3.medium EC2 behind an NLB, Aurora db.t3.medium (1 writer + 2 readers),
          Valkey cache.t3.medium x3, S3 bucket for cross-node cert sync

Creates (default full run — see PHASES below for the recommended order):
  1. Security groups (node: 22/80/443 open; rds + cache: node-SG only, no public access)
  2. EC2 key pair (saved to aws/{project}-{region}.pem)
  3. Aurora PostgreSQL cluster (db "postgres", user "postgres", random password)
  4. ElastiCache Valkey replication group (cluster mode disabled, not serverless)
  5. EC2 instance(s) with Elastic IPs (barebones AL2023, bootstrapped via user_data)
  6. S3 bucket for aws/certbot_sync.py (multi-node tiers only)
  7. Network Load Balancer, TCP passthrough on 80/443 (high tier only)
  8. EC2 environment setup (push var/django.conf, clone+deploy app, run migrations)
  9. SES domain verification + DKIM + SNS bounce/complaint/delivery hooks
  10. GitHub Actions secret (SYSTEM_UPDATE_TOKEN, for .github/workflows/deploy.yml)
  11. Verify — SSH smoke test of nginx/mojo-asgi/jobman/DB/cache on every node

PHASES for multi-node (high tier) — do NOT run these three as one big batch;
each has a manual checkpoint before the next:

  Phase 1 — Build node1 by hand (tier low/medium, EC2_COUNT=1):
    python aws/deploy.py                 # runs steps 1-10 above end to end
    ... manually run certbot on node1 (it's about to become PRIMARY_BALANCER_HOST) ...
    python aws/deploy.py --step verify   # confirm everything is actually green

  Phase 2 — Bake the golden AMI (--step bake-ami, NOT part of the default run —
  it's a deliberate one-time action, not something to redo on every full run):
    python aws/deploy.py --step bake-ami
    # Snapshots node1 as-is — no cloud-init/machine-id reset (see bake_ami()'s
    # docstring for why that's unnecessary and was actively harmful to node1's
    # own identity). Clones get their own hostname/SSH host key automatically
    # because each one has its own real EC2 instance-id.
    # Saves the resulting AMI as CUSTOM_AMI_ID in var/deploy.json.

  Phase 3 — Scale out from the AMI (bump EC2_COUNT in var/deploy.json first):
    python aws/deploy.py --step ec2      # new nodes launch from CUSTOM_AMI_ID,
                                          # skip the full bootstrap, only set
                                          # their own hostname via user-data
    python aws/deploy.py --step nlb      # registers the new node(s) — safe to
                                          # re-run, only registers what's missing
    python aws/deploy.py --step verify

Usage:
  python aws/deploy.py                    # Interactive - all steps
  python aws/deploy.py --region us-west-2 # Non-interactive region
  python aws/deploy.py --dry-run          # Show what would be created
  python aws/deploy.py --status           # Show current infrastructure status
  python aws/deploy.py --step sg          # Run only one step, see ALL_STEPS below
  python aws/deploy.py --init             # Re-run the setup wizard (overwrite var/deploy.json)

Deploy config: var/deploy.json (project name, domain, volume tier, instance sizes,
                AWS_KEY/AWS_SECRET, etc. — the single source of truth for everything
                deploy.py itself tracks)
"""
import argparse
import json
import os
import re
import sys
import stat
import time

VAR_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "var")
DEPLOY_JSON = os.path.join(VAR_DIR, "deploy.json")
DJANGO_CONF = os.path.join(VAR_DIR, "django.conf")


# ── var/deploy.json — single source of truth for everything deploy.py tracks ──
def _load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def _as_bool(v):
    """Lenient bool coercion — deploy.json normally stores real booleans, but
    tolerate hand-edits like "true"/"yes" too."""
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() in ("true", "1", "yes")


# ── var/django.conf — the actual Django settings file, KEY = value format is ──
# fixed by mojo.helpers.settings.parser.DjangoConfigLoader, not by us.
def _load_conf(path):
    """Load a key=value config file. Strips quotes from values."""
    vals = {}
    if not os.path.exists(path):
        return vals
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                key, val = line.split("=", 1)
                vals[key.strip()] = val.strip().strip("'\"")
    return vals


def load_credentials():
    """AWS creds for deploy.py's own boto3 calls live in var/deploy.json, not
    var/django.conf — a local dev setup might run against local Postgres/Redis
    with no AWS access at all, and shouldn't need real AWS creds just to
    satisfy this script. write_django_conf() copies them into django.conf's
    managed block for you once you actually provision something, since the
    deployed app does need them as real settings (S3/SES, etc)."""
    creds = _load_json(DEPLOY_JSON)
    if not creds.get("AWS_KEY") or not creds.get("AWS_SECRET"):
        print(f"ERROR: AWS_KEY and AWS_SECRET must be set in {DEPLOY_JSON}")
        sys.exit(1)
    return creds


# ── Deploy config (var/deploy.json) ──────────────────────────────────────────
def _detect_project_name():
    """Derive project name from the parent directory name.

    Must be hyphen-only, no underscores: this string becomes an RDS
    DBClusterIdentifier and an ElastiCache ReplicationGroupId, and AWS
    rejects underscores in both (letters/digits/hyphens only) — a project
    directory with an underscore in its name (e.g. reseaudent_api) would
    otherwise crash the very first `describe_db_clusters` existence check."""
    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    name = os.path.basename(project_dir).lower()
    # Strip common prefixes: "mojo-orchestra" → "orchestra", "django-myapp" → "myapp"
    for prefix in ("mojo-", "django-"):
        if name.startswith(prefix):
            name = name[len(prefix):]
    return re.sub(r"[^a-z0-9]+", "-", name).strip("-")


def _detect_github_repo():
    """Auto-detect owner/repo from `git remote get-url origin`. deploy.py is
    always run from inside the app repo it's deploying, so this should never
    need to be typed in — set GITHUB_REPO in var/deploy.json only to override
    (e.g. deploying a fork under a different name).

    Host-agnostic on purpose: SSH remotes are often written against a custom
    ~/.ssh/config Host alias for multi-account key management (e.g.
    git@github-work:owner/repo.git), not literally "github.com" — so this
    just takes the last two '/'-separated path segments, however the URL
    is shaped (scp-like SSH, ssh://, or https://[user@]host/...)."""
    import subprocess
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        url = subprocess.run(
            ["git", "-C", project_root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout.strip()
    except Exception:
        return None

    # Normalize scp-like SSH form ("user@host:path") to a plain path by
    # turning the last ':' before the path into a '/' — everything else
    # (https://, ssh://, ports) already uses '/' throughout.
    if "://" not in url and ":" in url:
        host_part, _, path_part = url.partition(":")
        url = f"{host_part}/{path_part}"

    path = url.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    parts = [p for p in path.split("/") if p]
    return f"{parts[-2]}/{parts[-1]}" if len(parts) >= 2 else None


def _generate_password(length=24):
    """Generate a random password for RDS."""
    import secrets
    import string
    chars = string.ascii_letters + string.digits
    return "".join(secrets.choice(chars) for _ in range(length))


def _generate_token(length=40):
    """Generate a random bearer token (e.g. SYSTEM_UPDATE_TOKEN)."""
    import secrets
    return secrets.token_urlsafe(length)


# Volume tiers — everything instance/node-count related derives from one choice.
# db.t3.medium is the smallest Aurora PostgreSQL instance class AWS offers;
# there is no db.t3.small.
TIER_DEFAULTS = {
    "low": {
        "INSTANCE_TYPE": "t3.small", "EC2_COUNT": 1,
        "DB_INSTANCE_CLASS": "db.t3.medium", "DB_READER_COUNT": 0,
        "CACHE_NODE_TYPE": "cache.t4g.small", "CACHE_NUM_NODES": 1,
        "USE_NLB": False,
    },
    "medium": {
        "INSTANCE_TYPE": "t3.medium", "EC2_COUNT": 1,
        "DB_INSTANCE_CLASS": "db.t3.medium", "DB_READER_COUNT": 1,
        "CACHE_NODE_TYPE": "cache.t3.medium", "CACHE_NUM_NODES": 2,
        "USE_NLB": False,
    },
    "high": {
        "INSTANCE_TYPE": "t3.medium", "EC2_COUNT": 2,
        "DB_INSTANCE_CLASS": "db.t3.medium", "DB_READER_COUNT": 2,
        "CACHE_NODE_TYPE": "cache.t3.medium", "CACHE_NUM_NODES": 3,
        "USE_NLB": True,
    },
}


def _run_setup_wizard(existing=None):
    """Interactive first-run wizard. Asks domain, region, and volume tier — derives the rest."""
    print("\n  ── Deploy Setup Wizard ──")
    print("  This creates var/deploy.json with your project settings.")
    print("  You can edit the file directly or re-run with --init.\n")

    existing = existing or {}
    project = _detect_project_name()

    domain_default = existing.get("DOMAIN", "")
    region_default = existing.get("REGION", "us-west-2")
    volume_default = existing.get("VOLUME", "medium")

    domain = input(f"  Production domain{f' [{domain_default}]' if domain_default else ''}: ").strip()
    domain = domain or domain_default
    if not domain:
        print("  ERROR: Domain is required (e.g. maestromojo.com)")
        sys.exit(1)

    region = input(f"  AWS region [{region_default}]: ").strip() or region_default

    import getpass
    aws_key_default = existing.get("AWS_KEY", "")
    key_hint = f" [{aws_key_default[:4]}...{aws_key_default[-4:]}]" if len(aws_key_default) > 8 else ""
    aws_key = input(f"  AWS Access Key ID (blank to set later){key_hint}: ").strip() or aws_key_default

    aws_secret_default = existing.get("AWS_SECRET", "")
    secret_hint = " [keep existing]" if aws_secret_default else ""
    aws_secret = getpass.getpass(f"  AWS Secret Access Key (blank to set later){secret_hint}: ").strip() or aws_secret_default

    volume = ""
    while volume not in TIER_DEFAULTS:
        volume = input(f"  Volume tier (low/medium/high) [{volume_default}]: ").strip().lower() or volume_default
        if volume not in TIER_DEFAULTS:
            print(f"  ERROR: volume must be one of: {', '.join(TIER_DEFAULTS)}")

    tier = TIER_DEFAULTS[volume]

    detected_repo = _detect_github_repo()
    if detected_repo:
        print(f"  (app repo auto-detected from git remote: {detected_repo})")

    # Auto-derive everything else
    vals = {
        "PROJECT": existing.get("PROJECT", project),
        "DOMAIN": domain,
        "REGION": region,
        "VOLUME": volume,
        "DB_NAME": existing.get("DB_NAME", "postgres"),
        "DB_USER": existing.get("DB_USER", "postgres"),
        "DB_PASSWORD": existing.get("DB_PASSWORD", _generate_password()),
        "SYSTEM_UPDATE_TOKEN": existing.get("SYSTEM_UPDATE_TOKEN", _generate_token()),
        "INSTANCE_TYPE": existing.get("INSTANCE_TYPE", tier["INSTANCE_TYPE"]),
        "EC2_COUNT": existing.get("EC2_COUNT", tier["EC2_COUNT"]),
        "DB_INSTANCE_CLASS": existing.get("DB_INSTANCE_CLASS", tier["DB_INSTANCE_CLASS"]),
        "DB_READER_COUNT": existing.get("DB_READER_COUNT", tier["DB_READER_COUNT"]),
        "CACHE_NODE_TYPE": existing.get("CACHE_NODE_TYPE", tier["CACHE_NODE_TYPE"]),
        "CACHE_NUM_NODES": existing.get("CACHE_NUM_NODES", tier["CACHE_NUM_NODES"]),
        "USE_NLB": existing.get("USE_NLB", tier["USE_NLB"]),
        "EMAIL_FROM": existing.get("EMAIL_FROM", f"noreply@{domain}"),
        "CUSTOM_AMI_ID": existing.get("CUSTOM_AMI_ID"),
        # Not prompted — auto-detected from git remote at use-time (see
        # _detect_github_repo()). Only carried through here so a manual
        # override in the file (e.g. deploying a fork) survives --init.
        "GITHUB_REPO": existing.get("GITHUB_REPO"),
        "AWS_KEY": aws_key,
        "AWS_SECRET": aws_secret,
    }

    _save_json(DEPLOY_JSON, vals)
    print(f"\n  ✓ Saved to {DEPLOY_JSON}")
    print(f"    Project:  {vals['PROJECT']}")
    print(f"    Domain:   {vals['DOMAIN']}")
    print(f"    Region:   {vals['REGION']}")
    print(f"    Volume:   {vals['VOLUME']}  (ec2 x{vals['EC2_COUNT']} {vals['INSTANCE_TYPE']}, "
          f"aurora {vals['DB_INSTANCE_CLASS']} +{vals['DB_READER_COUNT']} reader(s), "
          f"valkey {vals['CACHE_NODE_TYPE']} x{vals['CACHE_NUM_NODES']}"
          f"{', NLB' if _as_bool(vals['USE_NLB']) else ''})")
    print(f"    Database: {vals['DB_NAME']}")
    print(f"    Email:    {vals['EMAIL_FROM']}")
    print(f"    AWS creds: {'set' if vals['AWS_KEY'] and vals['AWS_SECRET'] else 'NOT set — add before running real steps'}")
    print(f"\n  Edit var/deploy.json to override any individual size/count.")
    return vals


def load_deploy_config(force_init=False):
    """Load deploy config from var/deploy.json. Runs the wizard — pre-filled
    with whatever's already in the file — if the file is missing, empty, or
    missing DOMAIN (the one field with no sensible default). A hand-written
    file (see aws/deploy.example.json) can just set DOMAIN and skip the rest:
    everything else falls back to volume-tier defaults in _init_config(), or
    can be answered interactively too by leaving it out and letting the
    wizard ask. --init always re-prompts everything, using current values as
    defaults. The two secrets (DB_PASSWORD, SYSTEM_UPDATE_TOKEN) can't have a
    static default, so if they're missing here we generate and persist them
    once, rather than silently leaving them blank."""
    existing = _load_json(DEPLOY_JSON)
    if force_init or not existing or not existing.get("DOMAIN"):
        return _run_setup_wizard(existing)

    changed = False
    if not existing.get("DB_PASSWORD"):
        existing["DB_PASSWORD"] = _generate_password()
        changed = True
    if not existing.get("SYSTEM_UPDATE_TOKEN"):
        existing["SYSTEM_UPDATE_TOKEN"] = _generate_token()
        changed = True
    if changed:
        _save_json(DEPLOY_JSON, existing)
        print(f"  ✓ Generated missing secret(s) in {DEPLOY_JSON}")

    return existing


# ── Config (loaded from var/deploy.json) ─────────────────────────────────────
# These module-level vars are set by _init_config() in main()
PROJECT = ""
DB_NAME = ""
DB_USER = ""
DB_PASSWORD = ""
SYSTEM_UPDATE_TOKEN = ""
INSTANCE_TYPE = ""
EC2_COUNT = 1
DB_INSTANCE_CLASS = ""
DB_READER_COUNT = 0
CACHE_NODE_TYPE = ""
CACHE_NUM_NODES = 2
USE_NLB = False
SES_DOMAIN = ""
SES_FROM_EMAIL = ""
AWS_KEY_CONF = ""
AWS_SECRET_CONF = ""
PEM_PATH_TEMPLATE = ""


def pem_file_path(region):
    """Where the EC2 private key lives. Defaults to aws/{project}-{region}.pem
    (this repo, region-scoped — the historical default), but is fully
    overridable via PEM_PATH in deploy.json for setups with their own key
    storage convention (e.g. "~/.ssh/idents/{project}.pem"). Supports
    {project}/{region} placeholders and '~' expansion."""
    if PEM_PATH_TEMPLATE:
        return os.path.expanduser(PEM_PATH_TEMPLATE.format(project=PROJECT, region=region))
    aws_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(aws_dir, f"{PROJECT}-{region}.pem")


def _init_config(conf):
    """Set module-level config vars from deploy.json values, falling back to the
    volume tier's defaults for anything not explicitly set in the file."""
    global PROJECT, DB_NAME, DB_USER, DB_PASSWORD, SYSTEM_UPDATE_TOKEN
    global INSTANCE_TYPE, EC2_COUNT, DB_INSTANCE_CLASS, DB_READER_COUNT
    global CACHE_NODE_TYPE, CACHE_NUM_NODES, USE_NLB
    global SES_DOMAIN, SES_FROM_EMAIL, AWS_KEY_CONF, AWS_SECRET_CONF, PEM_PATH_TEMPLATE

    tier = TIER_DEFAULTS.get(conf.get("VOLUME", "medium"), TIER_DEFAULTS["medium"])

    PROJECT = conf.get("PROJECT") or _detect_project_name()
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", PROJECT):
        print(f"  ERROR: PROJECT {PROJECT!r} in {DEPLOY_JSON} is invalid — it becomes an RDS/ElastiCache "
              f"identifier, so it must be lowercase letters/digits/hyphens only, and can't start/end with a hyphen.")
        sys.exit(1)
    DB_NAME = conf.get("DB_NAME", "postgres")
    DB_USER = conf.get("DB_USER", "postgres")
    DB_PASSWORD = conf.get("DB_PASSWORD", "")
    SYSTEM_UPDATE_TOKEN = conf.get("SYSTEM_UPDATE_TOKEN", "")
    AWS_KEY_CONF = conf.get("AWS_KEY", "")
    AWS_SECRET_CONF = conf.get("AWS_SECRET", "")
    INSTANCE_TYPE = conf.get("INSTANCE_TYPE", tier["INSTANCE_TYPE"])
    EC2_COUNT = int(conf.get("EC2_COUNT", tier["EC2_COUNT"]))
    DB_INSTANCE_CLASS = conf.get("DB_INSTANCE_CLASS", tier["DB_INSTANCE_CLASS"])
    DB_READER_COUNT = int(conf.get("DB_READER_COUNT", tier["DB_READER_COUNT"]))
    CACHE_NODE_TYPE = conf.get("CACHE_NODE_TYPE", tier["CACHE_NODE_TYPE"])
    CACHE_NUM_NODES = int(conf.get("CACHE_NUM_NODES", tier["CACHE_NUM_NODES"]))
    USE_NLB = _as_bool(conf.get("USE_NLB", tier["USE_NLB"]))
    SES_DOMAIN = conf.get("DOMAIN", "example.com")
    SES_FROM_EMAIL = conf.get("EMAIL_FROM", f"noreply@{SES_DOMAIN}")
    PEM_PATH_TEMPLATE = conf.get("PEM_PATH", "")


def get_boto_session(region, creds):
    import boto3
    return boto3.Session(
        aws_access_key_id=creds["AWS_KEY"],
        aws_secret_access_key=creds["AWS_SECRET"],
        region_name=region,
    )


def get_default_vpc(ec2):
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])
    if not vpcs["Vpcs"]:
        print("ERROR: No default VPC found in this region.")
        sys.exit(1)
    return vpcs["Vpcs"][0]["VpcId"]


def get_subnets(ec2, vpc_id):
    subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
    return [s["SubnetId"] for s in subnets["Subnets"]]


def get_subnet_azs(ec2, vpc_id):
    """Get subnets grouped by AZ — need at least 2 AZs for RDS subnet group."""
    subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
    return subnets["Subnets"]


def tag(name):
    return [{"Key": "Name", "Value": name}, {"Key": "Project", "Value": PROJECT}]


# ── Step 1: Security Groups ──────────────────────────────────────────────────
def setup_security_groups(session, vpc_id, dry_run=False):
    ec2 = session.client("ec2")
    existing = {sg["GroupName"]: sg for sg in ec2.describe_security_groups()["SecurityGroups"]}

    results = {}

    # Node SG (SSH, HTTP, HTTPS from anywhere)
    node_sg_name = f"{PROJECT}-nodes"
    if node_sg_name in existing:
        print(f"  ✓ {node_sg_name} already exists: {existing[node_sg_name]['GroupId']}")
        results["node"] = existing[node_sg_name]["GroupId"]
    elif dry_run:
        print(f"  [dry-run] Would create SG: {node_sg_name}")
        results["node"] = "sg-DRYRUN-node"
    else:
        resp = ec2.create_security_group(
            GroupName=node_sg_name,
            Description=f"{PROJECT} EC2 node - SSH, HTTP, HTTPS",
            VpcId=vpc_id,
            TagSpecifications=[{"ResourceType": "security-group", "Tags": tag(node_sg_name)}],
        )
        node_sg_id = resp["GroupId"]
        results["node"] = node_sg_id
        for port in [22, 80, 443]:
            ec2.authorize_security_group_ingress(
                GroupId=node_sg_id,
                IpPermissions=[{
                    "IpProtocol": "tcp",
                    "FromPort": port,
                    "ToPort": port,
                    "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
                }],
            )
        print(f"  ✓ Created {node_sg_name}: {node_sg_id} (SSH, HTTP, HTTPS)")

    # RDS SG (PostgreSQL from node SG only)
    rds_sg_name = f"{PROJECT}-rds"
    if rds_sg_name in existing:
        print(f"  ✓ {rds_sg_name} already exists: {existing[rds_sg_name]['GroupId']}")
        results["rds"] = existing[rds_sg_name]["GroupId"]
    elif dry_run:
        print(f"  [dry-run] Would create SG: {rds_sg_name}")
        results["rds"] = "sg-DRYRUN-rds"
    else:
        resp = ec2.create_security_group(
            GroupName=rds_sg_name,
            Description=f"{PROJECT} RDS - PostgreSQL from nodes only",
            VpcId=vpc_id,
            TagSpecifications=[{"ResourceType": "security-group", "Tags": tag(rds_sg_name)}],
        )
        rds_sg_id = resp["GroupId"]
        results["rds"] = rds_sg_id
        ec2.authorize_security_group_ingress(
            GroupId=rds_sg_id,
            IpPermissions=[{
                "IpProtocol": "tcp",
                "FromPort": 5432,
                "ToPort": 5432,
                "UserIdGroupPairs": [{"GroupId": results["node"]}],
            }],
        )
        print(f"  ✓ Created {rds_sg_name}: {rds_sg_id} (5432 from {node_sg_name})")

    # Cache SG (Redis/Valkey from node SG only)
    cache_sg_name = f"{PROJECT}-cache"
    if cache_sg_name in existing:
        print(f"  ✓ {cache_sg_name} already exists: {existing[cache_sg_name]['GroupId']}")
        results["cache"] = existing[cache_sg_name]["GroupId"]
    elif dry_run:
        print(f"  [dry-run] Would create SG: {cache_sg_name}")
        results["cache"] = "sg-DRYRUN-cache"
    else:
        resp = ec2.create_security_group(
            GroupName=cache_sg_name,
            Description=f"{PROJECT} cache - Valkey from nodes only",
            VpcId=vpc_id,
            TagSpecifications=[{"ResourceType": "security-group", "Tags": tag(cache_sg_name)}],
        )
        cache_sg_id = resp["GroupId"]
        results["cache"] = cache_sg_id
        ec2.authorize_security_group_ingress(
            GroupId=cache_sg_id,
            IpPermissions=[{
                "IpProtocol": "tcp",
                "FromPort": 6379,
                "ToPort": 6379,
                "UserIdGroupPairs": [{"GroupId": results["node"]}],
            }],
        )
        print(f"  ✓ Created {cache_sg_name}: {cache_sg_id} (6379 from {node_sg_name})")

    return results


# ── Step 2: Key Pair ──────────────────────────────────────────────────────────
def setup_key_pair(session, region, dry_run=False):
    ec2 = session.client("ec2")
    key_name = PROJECT
    pem_path = pem_file_path(region)

    existing = ec2.describe_key_pairs(Filters=[{"Name": "key-name", "Values": [key_name]}])
    if existing["KeyPairs"]:
        print(f"  ✓ Key pair '{key_name}' already exists: {existing['KeyPairs'][0]['KeyPairId']}")
        if os.path.exists(pem_path):
            print(f"    ✓ Private key found: {pem_path}")
        else:
            print(f"    ✗ Private key NOT found at {pem_path}")
            print(f"      If it's stored elsewhere, set PEM_PATH in {DEPLOY_JSON} (supports "
                  f"{{project}}/{{region}} placeholders and '~').")
        return key_name

    if dry_run:
        print(f"  [dry-run] Would create key pair: {key_name}")
        return key_name

    resp = ec2.create_key_pair(
        KeyName=key_name,
        KeyType="rsa",
        TagSpecifications=[{"ResourceType": "key-pair", "Tags": tag(key_name)}],
    )

    # Save the private key
    os.makedirs(os.path.dirname(pem_path), exist_ok=True)
    with open(pem_path, "w") as f:
        f.write(resp["KeyMaterial"])
    os.chmod(pem_path, stat.S_IRUSR)  # 0400
    print(f"  ✓ Created key pair '{key_name}', saved to {pem_path}")
    return key_name


# ── Step 3: Aurora PostgreSQL ─────────────────────────────────────────────────
def _find_rds_cluster_id(rds):
    """Adopt an existing Aurora cluster even if it doesn't follow the
    {PROJECT} naming convention — this account only ever runs one cluster,
    so if there's exactly one, it's ours. With more than one, only match by
    PROJECT prefix; never guess among ambiguous unrelated clusters."""
    try:
        clusters = rds.describe_db_clusters()["DBClusters"]
    except Exception:
        return None
    if len(clusters) == 1:
        return clusters[0]["DBClusterIdentifier"]
    for c in clusters:
        cid = c["DBClusterIdentifier"]
        if cid == PROJECT or cid.startswith(f"{PROJECT}-"):
            return cid
    return None


def _find_cache_replication_group_id(ec):
    """Same singleton-or-prefix-match logic as _find_rds_cluster_id(), for
    ElastiCache replication groups."""
    try:
        groups = ec.describe_replication_groups()["ReplicationGroups"]
    except Exception:
        return None
    if len(groups) == 1:
        return groups[0]["ReplicationGroupId"]
    for g in groups:
        gid = g["ReplicationGroupId"]
        if gid == f"{PROJECT}-cache" or gid.startswith(f"{PROJECT}-"):
            return gid
    return None


def setup_rds(session, vpc_id, sg_id, dry_run=False):
    rds = session.client("rds")
    ec2 = session.client("ec2")
    cluster_id = _find_rds_cluster_id(rds) or PROJECT

    # Check existing
    try:
        clusters = rds.describe_db_clusters(DBClusterIdentifier=cluster_id)
        c = clusters["DBClusters"][0]
        print(f"  ✓ Aurora cluster '{cluster_id}' already exists: {c['Status']}")
        print(f"    Endpoint: {c['Endpoint']}")
        return c["Endpoint"]
    except rds.exceptions.DBClusterNotFoundFault:
        pass

    if dry_run:
        print(f"  [dry-run] Would create Aurora cluster: {cluster_id}")
        print(f"    Engine: aurora-postgresql 17.4, Instance: {DB_INSTANCE_CLASS} "
              f"(1 writer + {DB_READER_COUNT} reader(s))")
        print(f"    DB: {DB_NAME}, User: {DB_USER}")
        return "DRYRUN-endpoint"

    # Create DB subnet group
    subnet_group = f"{PROJECT}-subnets"
    subnets = get_subnets(ec2, vpc_id)
    try:
        rds.describe_db_subnet_groups(DBSubnetGroupName=subnet_group)
        print(f"  ✓ Subnet group '{subnet_group}' already exists")
    except rds.exceptions.DBSubnetGroupNotFoundFault:
        rds.create_db_subnet_group(
            DBSubnetGroupName=subnet_group,
            DBSubnetGroupDescription=f"{PROJECT} Aurora subnets",
            SubnetIds=subnets,
            Tags=tag(subnet_group),
        )
        print(f"  ✓ Created subnet group: {subnet_group}")

    # Create cluster
    print(f"  Creating Aurora PostgreSQL cluster '{cluster_id}'...")
    rds.create_db_cluster(
        DBClusterIdentifier=cluster_id,
        Engine="aurora-postgresql",
        EngineVersion="17.4",
        MasterUsername=DB_USER,
        MasterUserPassword=DB_PASSWORD,
        DatabaseName=DB_NAME,
        DBSubnetGroupName=subnet_group,
        VpcSecurityGroupIds=[sg_id],
        StorageEncrypted=False,
        DeletionProtection=False,
        Tags=tag(cluster_id),
    )
    print(f"  ✓ Cluster creating...")

    # Create writer + reader instances — Aurora elects the first instance as
    # writer automatically; readers are just additional instances in the cluster.
    for i in range(1, DB_READER_COUNT + 2):
        instance_id = f"{cluster_id}-instance-{i}"
        role = "writer" if i == 1 else "reader"
        print(f"  Creating {role} instance '{instance_id}' ({DB_INSTANCE_CLASS})...")
        rds.create_db_instance(
            DBInstanceIdentifier=instance_id,
            DBClusterIdentifier=cluster_id,
            DBInstanceClass=DB_INSTANCE_CLASS,
            Engine="aurora-postgresql",
            Tags=tag(instance_id),
        )
    print(f"  ✓ {1 + DB_READER_COUNT} instance(s) creating... (this takes 5-10 minutes)")

    # Wait for cluster to be available
    print("  Waiting for cluster to become available...")
    waiter = rds.get_waiter("db_cluster_available")
    waiter.wait(DBClusterIdentifier=cluster_id, WaiterConfig={"Delay": 30, "MaxAttempts": 40})

    cluster = rds.describe_db_clusters(DBClusterIdentifier=cluster_id)["DBClusters"][0]
    endpoint = cluster["Endpoint"]
    print(f"  ✓ Aurora cluster ready: {endpoint}")
    return endpoint


# ── Step 4: ElastiCache Valkey ────────────────────────────────────────────────
def setup_cache(session, vpc_id, sg_id, dry_run=False):
    ec = session.client("elasticache")
    ec2 = session.client("ec2")
    repl_group = _find_cache_replication_group_id(ec) or f"{PROJECT}-cache"

    # Check existing
    try:
        groups = ec.describe_replication_groups(ReplicationGroupId=repl_group)
        rg = groups["ReplicationGroups"][0]
        print(f"  ✓ Replication group '{repl_group}' already exists: {rg['Status']}")
        for ng in rg.get("NodeGroups", []):
            ep = ng.get("PrimaryEndpoint", {})
            print(f"    Primary: {ep.get('Address', 'N/A')}:{ep.get('Port', 'N/A')}")
        ep = rg.get("NodeGroups", [{}])[0].get("PrimaryEndpoint", {})
        return ep.get("Address", "")
    except ec.exceptions.ReplicationGroupNotFoundFault:
        pass

    if dry_run:
        print(f"  [dry-run] Would create Valkey replication group: {repl_group}")
        print(f"    Engine: valkey, Nodes: {CACHE_NUM_NODES} x {CACHE_NODE_TYPE}")
        return "DRYRUN-cache-endpoint"

    # Create subnet group
    cache_subnet_group = f"{PROJECT}-cache-subnets"
    subnets = get_subnets(ec2, vpc_id)
    try:
        ec.describe_cache_subnet_groups(CacheSubnetGroupName=cache_subnet_group)
        print(f"  ✓ Cache subnet group '{cache_subnet_group}' already exists")
    except ec.exceptions.CacheSubnetGroupNotFoundFault:
        ec.create_cache_subnet_group(
            CacheSubnetGroupName=cache_subnet_group,
            CacheSubnetGroupDescription=f"{PROJECT} Valkey cache subnets",
            SubnetIds=subnets,
        )
        print(f"  ✓ Created cache subnet group: {cache_subnet_group}")

    print(f"  Creating Valkey replication group '{repl_group}'...")
    ec.create_replication_group(
        ReplicationGroupId=repl_group,
        ReplicationGroupDescription=f"{PROJECT} Valkey cache",
        Engine="valkey",
        CacheNodeType=CACHE_NODE_TYPE,
        NumCacheClusters=CACHE_NUM_NODES,
        CacheSubnetGroupName=cache_subnet_group,
        SecurityGroupIds=[sg_id],
        AutomaticFailoverEnabled=True if CACHE_NUM_NODES > 1 else False,
        TransitEncryptionEnabled=False,
        Tags=tag(repl_group),
    )
    print(f"  ✓ Replication group creating... (this takes 5-10 minutes)")

    # Wait for it
    print("  Waiting for cache to become available...")
    while True:
        time.sleep(30)
        groups = ec.describe_replication_groups(ReplicationGroupId=repl_group)
        status = groups["ReplicationGroups"][0]["Status"]
        print(f"    Status: {status}")
        if status == "available":
            break

    rg = groups["ReplicationGroups"][0]
    ep = rg.get("NodeGroups", [{}])[0].get("PrimaryEndpoint", {})
    endpoint = ep.get("Address", "")
    print(f"  ✓ Valkey cache ready: {endpoint}:{ep.get('Port', 6379)}")
    return endpoint


# ── Step 5: EC2 Instance(s) ────────────────────────────────────────────────────
def _node_hostname(i):
    """Hostname set on node i via TARGET_HOSTNAME — node 1 doubles as PRIMARY_BALANCER_HOST."""
    return f"{PROJECT}-node{i}"


def _find_free_eip(ec2):
    """Adopt an existing, unassociated Elastic IP instead of allocating a new
    one — same singleton-or-tag-match rule as RDS/ElastiCache. Only considers
    addresses with no InstanceId (i.e. not already attached to something)."""
    try:
        addrs = ec2.describe_addresses()["Addresses"]
    except Exception:
        return None
    free = [a for a in addrs if not a.get("InstanceId")]
    if len(free) == 1:
        return free[0]
    for a in free:
        tags = {t["Key"]: t["Value"] for t in a.get("Tags", [])}
        if tags.get("Project") == PROJECT:
            return a
    return None


def setup_ec2(session, region, vpc_id, sg_id, key_name, dry_run=False):
    """Create EC2_COUNT instances (node1..nodeN), each with its own Elastic IP.
    Returns a list of {instance_id, elastic_ip, hostname} dicts, node1 first.

    If CUSTOM_AMI_ID is set in deploy.json (via --step bake-ami), new instances
    launch from that golden image instead of stock AL2023 — skipping the full
    system bootstrap entirely — and only run a tiny hostname-setting user-data
    script. This works with no special prep on the golden image: each clone
    gets its own real EC2 instance-id, which cloud-init's datasource compares
    against the one cached on the AMI's disk (node1's, from when it was
    baked) — the mismatch makes cloud-init treat the clone as a genuinely new
    instance and run its first-boot modules (including this user-data and SSH
    host key generation) for real, same as it would for node1's own original
    first boot."""
    ec2 = session.client("ec2")
    nodes = []
    custom_ami_id = _load_json(DEPLOY_JSON).get("CUSTOM_AMI_ID") or ""

    images = None
    subnets = None

    for i in range(1, EC2_COUNT + 1):
        instance_name = f"{PROJECT}-{i}"
        hostname = _node_hostname(i)

        existing = ec2.describe_instances(
            Filters=[
                {"Name": "tag:Name", "Values": [instance_name]},
                {"Name": "instance-state-name", "Values": ["running", "stopped", "pending"]},
            ]
        )
        found = None
        for res in existing["Reservations"]:
            for inst in res["Instances"]:
                found = inst
        if found:
            print(f"  ✓ Instance '{instance_name}' already exists: {found['InstanceId']} ({found['State']['Name']})")
            print(f"    Public IP: {found.get('PublicIpAddress', 'N/A')}")
            nodes.append({"instance_id": found["InstanceId"], "elastic_ip": found.get("PublicIpAddress"), "hostname": hostname})
            continue

        if custom_ami_id:
            ami_id = custom_ami_id
            ami_label = f"{ami_id} (golden image)"
        else:
            if images is None:
                images = ec2.describe_images(
                    Owners=["amazon"],
                    Filters=[
                        {"Name": "name", "Values": ["al2023-ami-2023*-x86_64"]},
                        {"Name": "state", "Values": ["available"]},
                    ],
                )
            ami = sorted(images["Images"], key=lambda x: x["CreationDate"], reverse=True)[0]
            ami_id = ami["ImageId"]
            ami_label = f"{ami_id} ({ami['Name']})"

        if dry_run:
            print(f"  [dry-run] Would create EC2 instance: {instance_name} (hostname: {hostname})")
            print(f"    AMI: {ami_label}")
            print(f"    Type: {INSTANCE_TYPE}, Key: {key_name}")
            print(f"    + Elastic IP will be allocated and associated")
            nodes.append({"instance_id": f"i-DRYRUN{i}", "elastic_ip": "0.0.0.0", "hostname": hostname})
            continue

        if subnets is None:
            subnets = get_subnets(ec2, vpc_id)

        if custom_ami_id:
            # App, deps, and var/django.conf are already baked in — only the
            # per-node identity (hostname) needs setting on first boot.
            user_data = f"""#!/bin/bash
set -euo pipefail
hostnamectl set-hostname {hostname}
echo "{hostname}" > /etc/hostname
sed -i "s/127.0.0.1.*/127.0.0.1   localhost {hostname}/" /etc/hosts
"""
        else:
            # First-time node (no golden image yet) — full system bootstrap via curl.
            user_data = f"""#!/bin/bash
set -euo pipefail
export PROJ_PATH=/opt/api
export REMOVE_SSM=y
export TARGET_HOSTNAME={hostname}
curl -fsSL https://gist.githubusercontent.com/iamojo/6b422432719106aef8d713fb9a24ed67/raw/ec2_django_mojo_install.sh | bash
"""

        print(f"  Launching EC2 instance '{instance_name}' (hostname: {hostname}, AMI: {ami_label})...")
        resp = ec2.run_instances(
            ImageId=ami_id,
            InstanceType=INSTANCE_TYPE,
            KeyName=key_name,
            SecurityGroupIds=[sg_id],
            SubnetId=subnets[i % len(subnets)],
            MinCount=1,
            MaxCount=1,
            UserData=user_data,
            TagSpecifications=[{"ResourceType": "instance", "Tags": tag(instance_name)}],
            BlockDeviceMappings=[{
                "DeviceName": "/dev/xvda",
                "Ebs": {"VolumeSize": 30, "VolumeType": "gp3"},
            }],
        )
        instance_id = resp["Instances"][0]["InstanceId"]
        print(f"  ✓ Instance launching: {instance_id}")

        print("  Waiting for instance to be running...")
        waiter = ec2.get_waiter("instance_running")
        waiter.wait(InstanceIds=[instance_id])

        free_eip = _find_free_eip(ec2)
        if free_eip:
            elastic_ip = free_eip["PublicIp"]
            allocation_id = free_eip["AllocationId"]
            print(f"  ✓ Reusing existing unassociated Elastic IP: {elastic_ip}")
        else:
            print("  Allocating Elastic IP...")
            eip = ec2.allocate_address(
                Domain="vpc",
                TagSpecifications=[{"ResourceType": "elastic-ip", "Tags": tag(f"{instance_name}-eip")}],
            )
            elastic_ip = eip["PublicIp"]
            allocation_id = eip["AllocationId"]
            print(f"  ✓ Elastic IP: {elastic_ip} (AllocationId: {allocation_id})")
        ec2.associate_address(AllocationId=allocation_id, InstanceId=instance_id)

        print(f"  ✓ Instance running: {instance_id}")
        print(f"    SSH: ssh -i {pem_file_path(region)} ec2-user@{elastic_ip}")
        nodes.append({"instance_id": instance_id, "elastic_ip": elastic_ip, "hostname": hostname})

    return nodes


# ── Step 6: Cert bucket (multi-node cert sync via aws/certbot_sync.py) ────────
def setup_cert_bucket(session, dry_run=False):
    """Private S3 bucket aws/certbot_sync.py uses to share node1's Let's Encrypt
    cert with the rest of the fleet. Only needed when there's more than one node."""
    if EC2_COUNT <= 1:
        print("  Single node — no cert bucket needed (skipping).")
        return None

    from botocore.exceptions import ClientError
    s3 = session.client("s3")
    bucket = f"{PROJECT}-certs"

    try:
        s3.head_bucket(Bucket=bucket)
        print(f"  ✓ Bucket '{bucket}' already exists")
        return bucket
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") not in ("404", "NoSuchBucket"):
            raise

    if dry_run:
        print(f"  [dry-run] Would create private, encrypted S3 bucket: {bucket}")
        return bucket

    print(f"  Creating S3 bucket '{bucket}' for cert sync...")
    region = session.region_name
    create_kwargs = {"Bucket": bucket}
    if region != "us-east-1":
        create_kwargs["CreateBucketConfiguration"] = {"LocationConstraint": region}
    s3.create_bucket(**create_kwargs)
    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True, "IgnorePublicAcls": True,
            "BlockPublicPolicy": True, "RestrictPublicBuckets": True,
        },
    )
    s3.put_bucket_encryption(
        Bucket=bucket,
        ServerSideEncryptionConfiguration={
            "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
        },
    )
    print(f"  ✓ Created private, encrypted bucket: {bucket}")
    return bucket


def _register_missing_targets(elbv2, nodes, dry_run=False):
    """Register any node not already in the target groups — lets scale-out
    (more nodes launched from the golden AMI) join an already-created NLB."""
    node_ids = {n["instance_id"] for n in nodes}
    for tg_name, port in ((f"{PROJECT}-tg-80", 80), (f"{PROJECT}-tg-443", 443)):
        try:
            tg = elbv2.describe_target_groups(Names=[tg_name])["TargetGroups"][0]
        except elbv2.exceptions.TargetGroupNotFoundException:
            continue
        registered = {t["Target"]["Id"] for t in
                      elbv2.describe_target_health(TargetGroupArn=tg["TargetGroupArn"])["TargetHealthDescriptions"]}
        missing = node_ids - registered
        if not missing:
            continue
        if dry_run:
            print(f"  [dry-run] Would register {len(missing)} node(s) in {tg_name}")
            continue
        elbv2.register_targets(
            TargetGroupArn=tg["TargetGroupArn"],
            Targets=[{"Id": i, "Port": port} for i in missing],
        )
        print(f"  ✓ Registered {len(missing)} new node(s) in {tg_name}")


# ── Step 7: Network Load Balancer (TCP passthrough, high tier only) ──────────
def setup_nlb(session, vpc_id, nodes, dry_run=False):
    """Simple TCP-passthrough NLB across all nodes — TLS is still terminated by
    nginx on each node (see aws/certbot_sync.py for keeping certs in sync)."""
    if not USE_NLB:
        print("  USE_NLB is False for this tier — skipping.")
        return None

    elbv2 = session.client("elbv2")
    nlb_name = f"{PROJECT}-nlb"

    try:
        lb = elbv2.describe_load_balancers(Names=[nlb_name])["LoadBalancers"][0]
        print(f"  ✓ NLB '{nlb_name}' already exists: {lb['DNSName']}")
        _register_missing_targets(elbv2, nodes, dry_run=dry_run)
        return lb["DNSName"]
    except elbv2.exceptions.LoadBalancerNotFoundException:
        pass

    if dry_run:
        print(f"  [dry-run] Would create NLB '{nlb_name}' (TCP 80 + 443) across {len(nodes)} node(s)")
        return "DRYRUN-nlb.elb.amazonaws.com"

    ec2 = session.client("ec2")
    subnets = get_subnets(ec2, vpc_id)

    def _target_group(name, port):
        tg = elbv2.create_target_group(
            Name=name, Protocol="TCP", Port=port, VpcId=vpc_id,
            TargetType="instance", HealthCheckProtocol="TCP", HealthCheckPort="80",
            Tags=tag(name),
        )["TargetGroups"][0]
        elbv2.register_targets(
            TargetGroupArn=tg["TargetGroupArn"],
            Targets=[{"Id": n["instance_id"], "Port": port} for n in nodes],
        )
        return tg["TargetGroupArn"]

    print(f"  Creating target groups + registering {len(nodes)} node(s)...")
    tg80_arn = _target_group(f"{PROJECT}-tg-80", 80)
    tg443_arn = _target_group(f"{PROJECT}-tg-443", 443)

    print(f"  Creating NLB '{nlb_name}'...")
    lb = elbv2.create_load_balancer(
        Name=nlb_name, Type="network", Scheme="internet-facing",
        Subnets=subnets, Tags=tag(nlb_name),
    )["LoadBalancers"][0]
    lb_arn = lb["LoadBalancerArn"]

    elbv2.create_listener(LoadBalancerArn=lb_arn, Protocol="TCP", Port=80,
                           DefaultActions=[{"Type": "forward", "TargetGroupArn": tg80_arn}])
    elbv2.create_listener(LoadBalancerArn=lb_arn, Protocol="TCP", Port=443,
                           DefaultActions=[{"Type": "forward", "TargetGroupArn": tg443_arn}])

    print("  Waiting for NLB to become active...")
    waiter = elbv2.get_waiter("load_balancer_available")
    waiter.wait(LoadBalancerArns=[lb_arn])

    print(f"  ✓ NLB ready: {lb['DNSName']}")
    print(f"  Point {SES_DOMAIN} at this NLB in GoDaddy (CNAME — GoDaddy has no ALIAS-at-apex,")
    print(f"  so if {SES_DOMAIN} is your bare apex domain you'll need a subdomain instead):")
    print(f"    Type:  CNAME")
    print(f"    Value: {lb['DNSName']}")
    return lb["DNSName"]


def _find_nodes(session):
    """Look up the running instances for PROJECT-1..PROJECT-EC2_COUNT. Returns the
    same shape as setup_ec2(): list of {instance_id, elastic_ip, hostname}."""
    ec2 = session.client("ec2")
    nodes = []
    for i in range(1, EC2_COUNT + 1):
        instance_name = f"{PROJECT}-{i}"
        existing = ec2.describe_instances(
            Filters=[
                {"Name": "tag:Name", "Values": [instance_name]},
                {"Name": "instance-state-name", "Values": ["running"]},
            ]
        )
        for res in existing["Reservations"]:
            for inst in res["Instances"]:
                nodes.append({
                    "instance_id": inst["InstanceId"],
                    "elastic_ip": inst.get("PublicIpAddress"),
                    "hostname": _node_hostname(i),
                })
    return nodes


# ── Step 8: Bake golden AMI (manual — run once node1 is fully verified) ──────
def bake_ami(session, region, dry_run=False):
    """Snapshot node1 (always nodes[0] — the PRIMARY_BALANCER_HOST) into a
    reusable AMI so scale-out nodes launch fast from setup_ec2() instead of
    re-running the full system bootstrap.

    Deliberately does NOT touch cloud-init state or /etc/machine-id on node1
    before imaging — node1 is the live, already-running box, not a disposable
    template. EC2's cloud-init datasource keys per-instance first-boot
    behavior (hostname user-data, SSH host key generation, etc) off the real
    instance-id from the metadata service vs. the one cached on disk from the
    last boot. A clone launched from this AMI gets its own new real
    instance-id, which won't match node1's cached one, so cloud-init already
    re-runs first-boot setup for it automatically — that's what gives clones
    their own hostname (see setup_ec2()'s user_data) and their own SSH host
    key with zero manual cleanup. node1 itself reboots with the SAME
    instance-id it always had, so cloud-init correctly treats it as a normal
    reboot and leaves its hostname/SSH host key alone.

    (Previously this ran `cloud-init clean` on node1 first, on the mistaken
    assumption that was needed for clones to get a fresh identity. It wasn't
    — and it had the real side effect of also wiping node1's OWN "already
    initialized" state, making node1's own post-bake reboot regenerate ITS
    SSH host key too. Don't reintroduce that.)"""
    nodes = _find_nodes(session)
    if not nodes:
        print("  ERROR: No running instance found. Build and verify node1 first"
              " (sg/key/rds/cache/ec2/ec2-setup/verify).")
        return None

    node1 = nodes[0]
    pem_file = pem_file_path(region)

    if dry_run:
        print(f"  [dry-run] Would create AMI '{PROJECT}-golden-<timestamp>' from {node1['instance_id']} (reboots it)")
        return "ami-DRYRUN"

    if not os.path.exists(pem_file):
        print(f"  ERROR: Key file not found: {pem_file}")
        return None

    import subprocess
    print(f"  Ensuring services are enabled on {node1['hostname']} before imaging...")
    result = subprocess.run(
        ["ssh", "-i", pem_file, "-o", "StrictHostKeyChecking=no", f"ec2-user@{node1['elastic_ip']}", "sudo bash -s"],
        input="""set -euo pipefail
systemctl enable --now nginx crond rsyslog mojo-asgi
rm -f /opt/api/var/pids/*.pid
""",
        capture_output=True, text=True, timeout=60,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(f"  ERROR: pre-bake check failed (exit {result.returncode}): {result.stderr[-500:]}")
        print("  (mojo-asgi enable failing is expected if var/django.conf isn't fully configured yet — fix that first)")
        return None

    ec2 = session.client("ec2")
    ami_name = f"{PROJECT}-golden-{int(time.time())}"
    print(f"  Creating AMI '{ami_name}' from {node1['instance_id']} (this reboots the instance)...")
    resp = ec2.create_image(
        InstanceId=node1["instance_id"], Name=ami_name,
        Description=f"{PROJECT} golden image - baked from {node1['hostname']}",
        NoReboot=False,
        TagSpecifications=[{"ResourceType": "image", "Tags": tag(ami_name)}],
    )
    ami_id = resp["ImageId"]
    print(f"  ✓ AMI creating: {ami_id} (this can take several minutes)...")

    waiter = ec2.get_waiter("image_available")
    waiter.wait(ImageIds=[ami_id], WaiterConfig={"Delay": 15, "MaxAttempts": 80})
    print(f"  ✓ AMI ready: {ami_id}")

    conf = _load_json(DEPLOY_JSON)
    conf["CUSTOM_AMI_ID"] = ami_id
    _save_json(DEPLOY_JSON, conf)
    print(f"  ✓ Saved CUSTOM_AMI_ID={ami_id} to {DEPLOY_JSON}")
    print(f"\n  To scale out: bump EC2_COUNT in {DEPLOY_JSON}, then run:")
    print(f"    python aws/deploy.py --step ec2       # new nodes launch from this AMI (hostname-only setup)")
    print(f"    python aws/deploy.py --step nlb       # registers the new node(s) with the load balancer")
    print(f"    python aws/deploy.py --step verify")
    return ami_id


# ── Step 9: EC2 Setup (SSH in and configure) ─────────────────────────────────
def setup_ec2_environment(session, region, cert_bucket=None, dry_run=False):
    """For every node: push var/django.conf (+ var/ops.json on multi-node
    tiers), clone/pull the app repo via aws/remote_deploy.sh, then run
    migrations once from node 1 only."""
    nodes = _find_nodes(session)
    if not nodes:
        print("  ERROR: No running instance(s) found. Run --step ec2 first.")
        return

    pem_file = pem_file_path(region)
    if not os.path.exists(pem_file):
        print(f"  ERROR: Key file not found: {pem_file}")
        return

    if not dry_run and not os.path.exists(DJANGO_CONF):
        print(f"  ERROR: {DJANGO_CONF} doesn't exist yet — it's only written after both the "
              f"'rds' and 'cache' steps run (in the same invocation, e.g. a full run with no "
              f"--step flag). Run those first, or run a full `python aws/deploy.py`.")
        return

    repo = _load_json(DEPLOY_JSON).get("GITHUB_REPO") or _detect_github_repo() or ""
    remote_deploy_sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote_deploy.sh")
    ops = build_ops_json(cert_bucket=cert_bucket)

    if dry_run:
        for n in nodes:
            print(f"  [dry-run] Would push var/django.conf{' + var/ops.json' if ops else ''}"
                  f" to {n['elastic_ip']} and run remote_deploy.sh"
                  f"{f' --repo {repo}' if repo else ' (no --repo set — clone/deploy skipped, bootstrap only)'}")
        print("  [dry-run] Would run migrations from node 1 only")
        return

    if not repo:
        print("  NOTE: couldn't detect a GitHub repo (no git remote 'origin', or it's not a")
        print("        github.com URL) — nodes will be bootstrapped but the app repo won't be")
        print("        auto-cloned. Set GITHUB_REPO in var/deploy.json to override, or clone manually.")

    import subprocess
    import tempfile

    ops_file = None
    if ops:
        fd, ops_file = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(ops, f, indent=2)

    for n in nodes:
        ip = n["elastic_ip"]
        print(f"\n  ── {n['hostname']} ({ip}) ──")

        # setup_ec2()'s user_data already triggers bootstrap at boot time —
        # either the full ec2_bootstrap.sh (fresh AMI) or just the hostname
        # setup (golden AMI, already baked in). Racing our own SSH-triggered
        # bootstrap against that concurrently corrupts dnf/cloud-init's
        # python environment (both shebang on a bare "#!/usr/bin/python3"
        # that only the *other* run's alternatives-remap step would touch
        # mid-flight). Waiting it out and always passing --skip-bootstrap
        # below avoids the race entirely instead of hoping SSH-being-ready
        # means user_data is done.
        print("  Waiting for boot-time user-data (cloud-init) to finish...")
        subprocess.run(
            ["ssh", "-i", pem_file, "-o", "StrictHostKeyChecking=no", f"ec2-user@{ip}",
             "sudo cloud-init status --wait >/dev/null 2>&1 || true"],
        )

        print("  Pushing var/django.conf...")
        subprocess.run(
            ["scp", "-i", pem_file, "-o", "StrictHostKeyChecking=no", DJANGO_CONF,
             f"ec2-user@{ip}:/tmp/django.conf"],
            check=True,
        )
        subprocess.run(
            ["ssh", "-i", pem_file, "-o", "StrictHostKeyChecking=no", f"ec2-user@{ip}",
             "sudo mkdir -p /opt/api/var && sudo mv /tmp/django.conf /opt/api/var/django.conf "
             "&& echo prod | sudo tee /opt/api/var/profile >/dev/null "
             "&& sudo chown ec2-user:www /opt/api/var/django.conf /opt/api/var/profile"],
            check=True,
        )

        if ops_file:
            print("  Pushing var/ops.json (cert sync metadata)...")
            subprocess.run(
                ["scp", "-i", pem_file, "-o", "StrictHostKeyChecking=no", ops_file,
                 f"ec2-user@{ip}:/tmp/ops.json"],
                check=True,
            )
            subprocess.run(
                ["ssh", "-i", pem_file, "-o", "StrictHostKeyChecking=no", f"ec2-user@{ip}",
                 "sudo mv /tmp/ops.json /opt/api/var/ops.json "
                 "&& sudo chown ec2-user:www /opt/api/var/ops.json"],
                check=True,
            )

        # --skip-bootstrap: setup_ec2()'s user_data already handled it (or it's
        # baked into a golden AMI) — see the cloud-init wait above for why this
        # must never re-run concurrently with that.
        cmd = ["bash", remote_deploy_sh, ip, "--key", pem_file, "--skip-ossec", "--skip-bootstrap"]
        if repo:
            cmd += ["--repo", repo]
        result = subprocess.run(cmd)
        if result.returncode != 0:
            print(f"  WARN: remote_deploy.sh exited {result.returncode} for {n['hostname']}")

    if ops_file:
        os.remove(ops_file)

    if repo:
        print(f"\n  Running migrations from {nodes[0]['hostname']} only...")
        result = subprocess.run(
            ["ssh", "-i", pem_file, "-o", "StrictHostKeyChecking=no", f"ec2-user@{nodes[0]['elastic_ip']}",
             "cd /opt/api && python3 bin/manage.py migrate --noinput"],
        )
        if result.returncode != 0:
            print(f"  WARN: migrate exited {result.returncode} — check DB connectivity/credentials")
        else:
            print(f"  ✓ Migrations applied")


# ── Step 10: SES Domain Verification + DKIM ─────────────────────────────────
def setup_ses(session, region, dry_run=False):
    """Verify domain in SES and enable DKIM signing."""
    ses = session.client("ses")

    # Check current domain verification status
    try:
        attrs = ses.get_identity_verification_attributes(Identities=[SES_DOMAIN])
        status = attrs["VerificationAttributes"].get(SES_DOMAIN, {}).get("VerificationStatus")
    except Exception:
        status = None

    if status == "Success":
        print(f"  ✓ Domain '{SES_DOMAIN}' already verified")
    elif dry_run:
        print(f"  [dry-run] Would verify domain: {SES_DOMAIN}")
        print(f"  [dry-run] Would enable DKIM for: {SES_DOMAIN}")
        return
    else:
        if status == "Pending":
            print(f"  ⧖ Domain '{SES_DOMAIN}' verification pending — check DNS records below")
        else:
            print(f"  Verifying domain '{SES_DOMAIN}'...")
            ses.verify_domain_identity(Domain=SES_DOMAIN)
            print(f"  ✓ Domain verification initiated")

        # Get the TXT verification token
        attrs = ses.get_identity_verification_attributes(Identities=[SES_DOMAIN])
        token = attrs["VerificationAttributes"].get(SES_DOMAIN, {}).get("VerificationToken", "")
        if token:
            print(f"\n  Add this DNS TXT record to verify domain ownership:")
            print(f"    Name:  _amazonses.{SES_DOMAIN}")
            print(f"    Type:  TXT")
            print(f"    Value: {token}")

    # DKIM
    try:
        dkim_attrs = ses.get_identity_dkim_attributes(Identities=[SES_DOMAIN])
        dkim_status = dkim_attrs["DkimAttributes"].get(SES_DOMAIN, {}).get("DkimVerificationStatus")
        dkim_tokens = dkim_attrs["DkimAttributes"].get(SES_DOMAIN, {}).get("DkimTokens", [])
    except Exception:
        dkim_status = None
        dkim_tokens = []

    if dkim_status == "Success":
        print(f"  ✓ DKIM already verified for '{SES_DOMAIN}'")
    else:
        if not dkim_tokens:
            print(f"\n  Enabling DKIM for '{SES_DOMAIN}'...")
            resp = ses.verify_domain_dkim(Domain=SES_DOMAIN)
            dkim_tokens = resp.get("DkimTokens", [])
            print(f"  ✓ DKIM initiated")

        if dkim_tokens:
            print(f"\n  Add these 3 DNS CNAME records for DKIM:")
            for token in dkim_tokens:
                print(f"    Name:  {token}._domainkey.{SES_DOMAIN}")
                print(f"    Type:  CNAME")
                print(f"    Value: {token}.dkim.amazonses.com")
                print()

    # MAIL FROM (optional but improves deliverability)
    mail_from_domain = f"mail.{SES_DOMAIN}"
    try:
        mf_attrs = ses.get_identity_mail_from_domain_attributes(Identities=[SES_DOMAIN])
        current_mf = mf_attrs["MailFromDomainAttributes"].get(SES_DOMAIN, {}).get("MailFromDomain", "")
    except Exception:
        current_mf = ""

    if current_mf == mail_from_domain:
        print(f"  ✓ MAIL FROM already set to '{mail_from_domain}'")
    else:
        if not dry_run:
            ses.set_identity_mail_from_domain(
                Identity=SES_DOMAIN,
                MailFromDomain=mail_from_domain,
            )
        print(f"  ✓ MAIL FROM set to '{mail_from_domain}'")
        print(f"\n  Add these DNS records for MAIL FROM:")
        print(f"    Name:  {mail_from_domain}")
        print(f"    Type:  MX")
        print(f"    Value: 10 feedback-smtp.{region}.amazonses.com")
        print()
        print(f"    Name:  {mail_from_domain}")
        print(f"    Type:  TXT")
        print(f"    Value: \"v=spf1 include:amazonses.com ~all\"")

    # SNS topics for bounce/complaint/delivery notifications
    sns = session.client("sns")
    base_domain = SES_DOMAIN.replace(".", "-")
    webhook_base = f"https://{SES_DOMAIN}/api/email/sns"
    topic_types = {
        "bounce": f"ses-{base_domain}-bounce",
        "complaint": f"ses-{base_domain}-complaint",
        "delivery": f"ses-{base_domain}-delivery",
    }

    print(f"\n  Setting up SNS notification topics...")
    topic_arns = {}
    for notif_type, topic_name in topic_types.items():
        if dry_run:
            print(f"  [dry-run] Would create SNS topic: {topic_name}")
            continue

        # create_topic is idempotent — returns existing ARN if already exists
        resp = sns.create_topic(
            Name=topic_name,
            Tags=[{"Key": "Project", "Value": PROJECT}, {"Key": "Type", "Value": notif_type}],
        )
        arn = resp["TopicArn"]
        topic_arns[notif_type] = arn
        print(f"  ✓ SNS topic: {topic_name} ({arn})")

        # Map topic to SES identity notifications
        ses.set_identity_notification_topic(
            Identity=SES_DOMAIN,
            NotificationType=notif_type.capitalize(),
            SnsTopic=arn,
        )
        print(f"    → mapped to SES {notif_type} notifications")

        # Subscribe our webhook endpoint (idempotent)
        endpoint = f"{webhook_base}/{notif_type}"
        sns.subscribe(
            TopicArn=arn,
            Protocol="https",
            Endpoint=endpoint,
            ReturnSubscriptionArn=True,
        )
        print(f"    → subscribed: {endpoint}")

    if not dry_run and topic_arns:
        # Disable email notifications (we use SNS instead)
        for notif_type in ["Bounce", "Complaint", "Delivery"]:
            ses.set_identity_headers_in_notifications_enabled(
                Identity=SES_DOMAIN,
                NotificationType=notif_type,
                Enabled=True,
            )
        ses.set_identity_feedback_forwarding_enabled(
            Identity=SES_DOMAIN,
            ForwardingEnabled=False,
        )
        print(f"  ✓ Email forwarding disabled (using SNS only)")
        print(f"\n  NOTE: SNS subscriptions require confirmation.")
        print(f"    Your server must be running at {webhook_base}/* to auto-confirm.")
        print(f"    django-mojo handles confirmation automatically.")

    # Check sandbox status
    try:
        account = ses.get_send_quota()
        max_24hr = account.get("Max24HourSend", 0)
        if max_24hr <= 200:
            print(f"\n  ⚠ SES is in SANDBOX mode (limit: {max_24hr}/day)")
            print(f"    You can only send to verified email addresses.")
            print(f"    Request production access in the AWS console:")
            print(f"    https://{region}.console.aws.amazon.com/ses/home?region={region}#/account")
        else:
            print(f"\n  ✓ SES production access (limit: {max_24hr}/day)")
    except Exception:
        pass

    print(f"\n  From address: {SES_FROM_EMAIL}")
    print(f"  Set EMAIL_FROM = \"{SES_FROM_EMAIL}\" in var/django.conf")


# ── Status ────────────────────────────────────────────────────────────────────
def show_status(session, region):
    ec2 = session.client("ec2")
    rds = session.client("rds")
    ec = session.client("elasticache")

    print(f"\n{'='*60}")
    print(f"  Mojo Orchestra — {region}")
    print(f"{'='*60}")

    # Security groups
    print("\n── Security Groups ──")
    for name in [f"{PROJECT}-nodes", f"{PROJECT}-rds", f"{PROJECT}-cache"]:
        sgs = ec2.describe_security_groups(Filters=[{"Name": "group-name", "Values": [name]}])
        if sgs["SecurityGroups"]:
            sg = sgs["SecurityGroups"][0]
            print(f"  ✓ {name}: {sg['GroupId']}")
        else:
            print(f"  ✗ {name}: not found")

    # Key pair
    print("\n── Key Pair ──")
    keys = ec2.describe_key_pairs(Filters=[{"Name": "key-name", "Values": [PROJECT]}])
    if keys["KeyPairs"]:
        print(f"  ✓ {PROJECT}: {keys['KeyPairs'][0]['KeyPairId']}")
    else:
        print(f"  ✗ {PROJECT}: not found")

    # RDS — adopts a lone existing cluster even if it doesn't match {PROJECT}
    # (see _find_rds_cluster_id): this account only ever runs one.
    print("\n── Aurora PostgreSQL ──")
    cluster_id = _find_rds_cluster_id(rds) or PROJECT
    try:
        clusters = rds.describe_db_clusters(DBClusterIdentifier=cluster_id)
        c = clusters["DBClusters"][0]
        print(f"  ✓ {cluster_id}: {c['Status']}")
        print(f"    Endpoint: {c['Endpoint']}")
        print(f"    Port: {c['Port']} | DB: {c.get('DatabaseName', 'N/A')}")
    except rds.exceptions.DBClusterNotFoundFault:
        print(f"  ✗ {cluster_id}: not found")

    # ElastiCache — same singleton-or-prefix-match adoption as RDS above.
    print("\n── Valkey Cache ──")
    repl_group = _find_cache_replication_group_id(ec) or f"{PROJECT}-cache"
    try:
        groups = ec.describe_replication_groups(ReplicationGroupId=repl_group)
        rg = groups["ReplicationGroups"][0]
        print(f"  ✓ {repl_group}: {rg['Status']}")
        for ng in rg.get("NodeGroups", []):
            ep = ng.get("PrimaryEndpoint", {})
            print(f"    Primary: {ep.get('Address', 'N/A')}:{ep.get('Port', 'N/A')}")
    except ec.exceptions.ReplicationGroupNotFoundFault:
        print(f"  ✗ {repl_group}: not found")

    # SES
    print("\n── SES Email ──")
    try:
        ses = session.client("ses")
        attrs = ses.get_identity_verification_attributes(Identities=[SES_DOMAIN])
        v_status = attrs["VerificationAttributes"].get(SES_DOMAIN, {}).get("VerificationStatus", "not configured")
        dkim_attrs = ses.get_identity_dkim_attributes(Identities=[SES_DOMAIN])
        d_status = dkim_attrs["DkimAttributes"].get(SES_DOMAIN, {}).get("DkimVerificationStatus", "not configured")
        quota = ses.get_send_quota()
        max_send = quota.get("Max24HourSend", 0)
        sent = quota.get("SentLast24Hours", 0)
        mode = "production" if max_send > 200 else "sandbox"
        print(f"  Domain: {SES_DOMAIN} — verification: {v_status}, DKIM: {d_status}")
        print(f"  Mode: {mode} | Sent: {int(sent)}/{int(max_send)} (24hr)")
    except Exception as e:
        print(f"  ✗ Could not check SES: {e}")

    # SNS topics
    print("\n── SNS Topics ──")
    try:
        sns_client = session.client("sns")
        base_domain = SES_DOMAIN.replace(".", "-")
        for notif_type in ["bounce", "complaint", "delivery"]:
            topic_name = f"ses-{base_domain}-{notif_type}"
            # List subscriptions by looking up the topic
            try:
                topic_arn = f"arn:aws:sns:{region}:{session.client('sts').get_caller_identity()['Account']}:{topic_name}"
                subs = sns_client.list_subscriptions_by_topic(TopicArn=topic_arn)
                sub_count = len(subs.get("Subscriptions", []))
                sub_status = subs["Subscriptions"][0]["SubscriptionArn"] if sub_count else "none"
                confirmed = "confirmed" if sub_status.startswith("arn:") else sub_status
                print(f"  ✓ {topic_name}: {sub_count} subscription(s) ({confirmed})")
            except Exception:
                print(f"  ✗ {topic_name}: not found")
    except Exception as e:
        print(f"  ✗ Could not check SNS: {e}")

    # Elastic IPs — show tagged ones plus any free/untagged ones setup_ec2()
    # would adopt via _find_free_eip() rather than allocating a new one.
    print("\n── Elastic IPs ──")
    all_addrs = ec2.describe_addresses()["Addresses"]
    tagged = [a for a in all_addrs if any(t["Key"] == "Project" and t["Value"] == PROJECT for t in a.get("Tags", []))]
    free_unassociated = [a for a in all_addrs if not a.get("InstanceId")]
    shown_ids = set()
    found = False
    for eip in tagged:
        name = next((t["Value"] for t in eip.get("Tags", []) if t["Key"] == "Name"), "")
        print(f"  ✓ {name or '(untagged)'}: {eip['PublicIp']} → {eip.get('InstanceId', 'unattached')}")
        shown_ids.add(eip["AllocationId"])
        found = True
    for eip in free_unassociated:
        if eip["AllocationId"] in shown_ids:
            continue
        print(f"  ✓ (unassociated, no Project tag — would be adopted): {eip['PublicIp']}")
        found = True
    if not found:
        print(f"  ✗ No elastic IPs found")

    # EC2
    print("\n── EC2 Instances ──")
    instances = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Project", "Values": [PROJECT]},
            {"Name": "instance-state-name", "Values": ["running", "stopped", "pending"]},
        ]
    )
    found = False
    for res in instances["Reservations"]:
        for inst in res["Instances"]:
            name = ""
            for t in inst.get("Tags", []):
                if t["Key"] == "Name":
                    name = t["Value"]
            print(f"  ✓ {name}: {inst['InstanceId']} | {inst['InstanceType']} | {inst['State']['Name']}")
            print(f"    IP: {inst.get('PublicIpAddress', 'N/A')}")
            found = True
    if not found:
        print(f"  ✗ No instances found")

    # NLB (high tier only)
    print("\n── Network Load Balancer ──")
    try:
        elbv2 = session.client("elbv2")
        lb = elbv2.describe_load_balancers(Names=[f"{PROJECT}-nlb"])["LoadBalancers"][0]
        print(f"  ✓ {PROJECT}-nlb: {lb['State']['Code']} — {lb['DNSName']}")
    except Exception:
        print(f"  ✗ {PROJECT}-nlb: not found")

    # Cert sync bucket (multi-node only)
    print("\n── Cert Sync Bucket ──")
    try:
        session.client("s3").head_bucket(Bucket=f"{PROJECT}-certs")
        print(f"  ✓ {PROJECT}-certs")
    except Exception:
        print(f"  ✗ {PROJECT}-certs: not found")

    print()


# ── Generate var/django.conf for production ───────────────────────────────────
DJANGO_CONF_BEGIN = "# ── BEGIN aws/deploy.py managed block — safe to edit values, do not remove markers ──"
DJANGO_CONF_END = "# ── END aws/deploy.py managed block ──"


def write_django_conf(region, db_endpoint, cache_endpoint):
    """Merge deploy-derived settings into var/django.conf, replacing only the
    managed block between the markers — anything else in the file (SECRET_KEY,
    hand-added local-dev settings) is left untouched.

    AWS_KEY/AWS_SECRET come from var/deploy.json (see load_credentials()) and
    get copied in here too, since the *deployed app* needs them as real
    settings (S3/SES, etc) even though deploy.py's own boto3 calls don't read
    them from this file. LOAD_BALANCER_DOMAIN/PRIMARY_BALANCER_HOST/
    AWS_CERT_BUCKET are deploy/ops metadata the app itself never reads —
    those live in var/ops.json instead (see build_ops_json())."""
    lines = []
    if os.path.exists(DJANGO_CONF):
        with open(DJANGO_CONF) as f:
            lines = f.read().splitlines()

    block = [
        DJANGO_CONF_BEGIN,
        f'AWS_REGION = "{region}"',
        f'AWS_KEY = "{AWS_KEY_CONF}"',
        f'AWS_SECRET = "{AWS_SECRET_CONF}"',
        f'DATABASE_HOST = "{db_endpoint}"',
        'DATABASE_PORT = "5432"',
        f'DATABASE_NAME = "{DB_NAME}"',
        f'DATABASE_USER = "{DB_USER}"',
        f'DATABASE_PASSWORD = "{DB_PASSWORD}"',
        f'REDIS_SERVER = "{cache_endpoint}"',
        'REDIS_PORT = "6379"',
        f'EMAIL_FROM = "{SES_FROM_EMAIL}"',
        f'SYSTEM_UPDATE_TOKEN = "{SYSTEM_UPDATE_TOKEN}"',
        DJANGO_CONF_END,
    ]

    if DJANGO_CONF_BEGIN in lines:
        start = lines.index(DJANGO_CONF_BEGIN)
        end = lines.index(DJANGO_CONF_END) + 1
        lines[start:end] = block
    else:
        if lines and lines[-1].strip():
            lines.append("")
        lines += block

    os.makedirs(VAR_DIR, exist_ok=True)
    with open(DJANGO_CONF, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"  ✓ Wrote deploy settings to {DJANGO_CONF}")
    if not AWS_KEY_CONF or not AWS_SECRET_CONF:
        print(f"  NOTE: AWS_KEY/AWS_SECRET are blank — set them in {DEPLOY_JSON} and re-run.")


def build_ops_json(cert_bucket=None):
    """Deploy/ops metadata pushed to every node as var/ops.json — read by
    aws/certbot_sync.py and ec2_deploy.sh's certbot messaging. Not Django
    settings (see write_django_conf) since the app itself never reads these.
    Returns None for single-node deploys — nothing to sync, no file needed."""
    if EC2_COUNT <= 1:
        return None
    return {
        "LOAD_BALANCER_DOMAIN": SES_DOMAIN,
        "PRIMARY_BALANCER_HOST": _node_hostname(1),
        "AWS_CERT_BUCKET": cert_bucket or f"{PROJECT}-certs",
    }


# ── Step 10: GitHub Actions secret ───────────────────────────────────────────
def ensure_github_secret(dry_run=False):
    """Push SYSTEM_UPDATE_TOKEN to the repo as a GitHub Actions secret, for
    .github/workflows/deploy.yml's fleet-update trigger on push to main.

    `gh` frequently can't do this even when installed: it's commonly
    authenticated as a personal account with no access to the org/repo being
    deployed (a 404, not an auth prompt — gh gives no signal to tell the two
    apart; see aws/remote_deploy.sh's deploy-key step for the same situation).
    That means the manual fallback below is the normal path here, not a rare
    edge case, so it always prints the exact secret name + value + UI steps
    rather than just suggesting "check gh auth status"."""
    import subprocess

    repo = _load_json(DEPLOY_JSON).get("GITHUB_REPO") or _detect_github_repo()
    if not repo:
        print("  NOTE: couldn't detect a GitHub repo — skipping GitHub Actions secret setup.")
        print("        Set GITHUB_REPO in var/deploy.json to override, then re-run this step.")
        return

    if dry_run:
        print(f"  [dry-run] Would set SYSTEM_UPDATE_TOKEN secret on {repo}")
        return

    ok = False
    try:
        result = subprocess.run(
            ["gh", "secret", "set", "SYSTEM_UPDATE_TOKEN", "--repo", repo, "--body", SYSTEM_UPDATE_TOKEN],
            capture_output=True, text=True, timeout=15,
        )
        ok = result.returncode == 0
        if not ok and result.stderr:
            print(f"  gh error: {result.stderr.strip()}")
    except FileNotFoundError:
        pass  # gh not installed — fall through to manual instructions
    except Exception as e:
        print(f"  gh error: {e}")

    if ok:
        print(f"  ✓ SYSTEM_UPDATE_TOKEN secret set on {repo} via gh")
        return

    print()
    print("  ==========================================================")
    print("   GitHub Actions secret needs to be added manually")
    print("  ==========================================================")
    print("   gh couldn't set it automatically (not installed, or")
    print(f"   authenticated as an account without access to {repo}).")
    print()
    print(f"   1. Open: https://github.com/{repo}/settings/secrets/actions")
    print("   2. Click 'New repository secret'")
    print("   3. Name:  SYSTEM_UPDATE_TOKEN")
    print(f"   4. Value: {SYSTEM_UPDATE_TOKEN}")
    print("   5. Click 'Add secret'")
    print("  ==========================================================")
    print()


# ── Step 11: Verify (smoke test the fleet) ───────────────────────────────────
def verify_deployment(session, region, dry_run=False):
    """SSH into every node and check: nginx up, mojo-asgi up, jobman engine up,
    and DB/Redis connectivity via the app's own `manage.py status` (real
    connection settings, not a hand-rolled psql/redis-cli reimplementation).
    Best-effort curl of the public domain/NLB too."""
    nodes = _find_nodes(session)
    if not nodes:
        print("  ERROR: No running instance(s) found.")
        return

    pem_file = pem_file_path(region)
    if dry_run:
        print(f"  [dry-run] Would SSH into {len(nodes)} node(s) and check nginx/mojo-asgi/jobman + run manage.py status")
        return
    if not os.path.exists(pem_file):
        print(f"  ERROR: Key file not found: {pem_file}")
        return

    check_script = r"""
set -uo pipefail
ok() { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; }

systemctl is-active --quiet nginx && ok "nginx running" || bad "nginx not running"
systemctl is-active --quiet mojo-asgi && ok "mojo-asgi running" || bad "mojo-asgi not running (configure var/django.conf + enable it?)"
pgrep -f "bin/jobs.py engine" >/dev/null && ok "jobman engine running" || bad "jobman engine not running"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost/ || echo "000")
[[ "$CODE" != "000" ]] && ok "nginx answers on :80 (HTTP $CODE)" || bad "nginx not answering on :80"

if [[ -f /opt/api/var/django.conf ]]; then
    cd /opt/api
    echo "  -- manage.py status (DB + Redis, via the app's own connection settings) --"
    python3 /opt/api/bin/manage.py status --timeout 5 --exit-code \
        && ok "manage.py status: all checks passed" \
        || bad "manage.py status: one or more checks failed (see output above)"
else
    bad "no /opt/api/var/django.conf on this node yet — run --step ec2-setup first"
fi
"""

    import subprocess
    for n in nodes:
        print(f"\n  ── {n['hostname']} ({n['elastic_ip']}) ──")
        result = subprocess.run(
            ["ssh", "-i", pem_file, "-o", "StrictHostKeyChecking=no", f"ec2-user@{n['elastic_ip']}", "bash -s"],
            input=check_script, capture_output=True, text=True, timeout=60,
        )
        print(result.stdout)
        if result.stderr.strip():
            print(f"  stderr: {result.stderr.strip()[-500:]}")

    if USE_NLB:
        elbv2 = session.client("elbv2")
        try:
            lb = elbv2.describe_load_balancers(Names=[f"{PROJECT}-nlb"])["LoadBalancers"][0]
            code = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", f"http://{lb['DNSName']}/"],
                capture_output=True, text=True,
            ).stdout
            print(f"\n  NLB {lb['DNSName']}: HTTP {code or '(no response)'}")
        except elbv2.exceptions.LoadBalancerNotFoundException:
            print("\n  NLB not found — run --step nlb first")

    print(f"\n  Public domain check (best-effort, requires DNS pointed + cert issued):")
    for scheme in ("http", "https"):
        code = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", f"{scheme}://{SES_DOMAIN}/"],
            capture_output=True, text=True,
        ).stdout
        print(f"    {scheme}://{SES_DOMAIN}/  → HTTP {code or '(no response)'}")


# ── Main ──────────────────────────────────────────────────────────────────────
# Default full run — everything needed to get node1 live. "bake-ami" is
# deliberately excluded: it's a manual, one-time action you run once node1 is
# verified, not something a full run should silently redo.
STEPS = ["sg", "key", "rds", "cache", "ec2", "cert-bucket", "nlb", "ec2-setup", "ses", "github-secret", "verify"]
ALL_STEPS = STEPS + ["bake-ami"]


def main():
    parser = argparse.ArgumentParser(description="Deploy project infrastructure to AWS")
    parser.add_argument("--region", help="AWS region (overrides deploy.json)")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be created")
    parser.add_argument("--status", action="store_true", help="Show current infrastructure")
    parser.add_argument("--step", choices=ALL_STEPS, help="Run only one step")
    parser.add_argument("--yes", "-y", action="store_true", help="Skip confirmation prompts")
    parser.add_argument("--init", action="store_true", help="Re-run setup wizard (overwrite var/deploy.json)")
    args = parser.parse_args()

    # Load or create deploy config
    conf = load_deploy_config(force_init=args.init)
    _init_config(conf)

    if args.init:
        print("\n  Config saved. Run again without --init to deploy.")
        return

    creds = load_credentials()

    region = args.region or conf.get("REGION", "us-west-2")
    session = get_boto_session(region, creds)

    if args.status:
        show_status(session, region)
        return

    print(f"\n  {PROJECT} AWS Deploy → {region}")
    print(f"  {'(DRY RUN)' if args.dry_run else ''}")
    print(f"  {'='*50}\n")

    if not args.yes and not args.dry_run:
        confirm = input(f"  Deploy to {region}? [y/N] ")
        if confirm.lower() != "y":
            print("  Aborted.")
            return

    ec2 = session.client("ec2")
    vpc_id = get_default_vpc(ec2)
    print(f"  Using default VPC: {vpc_id}\n")

    steps_to_run = [args.step] if args.step else STEPS
    sg_ids = {}
    db_endpoint = ""
    cache_endpoint = ""
    nodes = []
    cert_bucket = None

    # Always load existing SG IDs if skipping SG step. sg_ids keys ("node") are
    # our own internal names — the "nodes" AWS SG name itself is plural (see
    # setup_security_groups()'s node_sg_name), so they're mapped separately.
    if "sg" not in steps_to_run:
        ec2_client = session.client("ec2")
        for sg_key, aws_suffix in [("node", "nodes"), ("rds", "rds"), ("cache", "cache")]:
            sg_name = f"{PROJECT}-{aws_suffix}"
            sgs = ec2_client.describe_security_groups(Filters=[{"Name": "group-name", "Values": [sg_name]}])
            if sgs["SecurityGroups"]:
                sg_ids[sg_key] = sgs["SecurityGroups"][0]["GroupId"]

    for step in steps_to_run:
        if step == "sg":
            print("── Step 1: Security Groups ──")
            sg_ids = setup_security_groups(session, vpc_id, dry_run=args.dry_run)
            print()

        elif step == "key":
            print("── Step 2: Key Pair ──")
            setup_key_pair(session, region, dry_run=args.dry_run)
            print()

        elif step == "rds":
            print("── Step 3: Aurora PostgreSQL ──")
            if "rds" not in sg_ids:
                print("  ERROR: RDS security group not found. Run --step sg first.")
                continue
            db_endpoint = setup_rds(session, vpc_id, sg_ids["rds"], dry_run=args.dry_run)
            print()

        elif step == "cache":
            print("── Step 4: Valkey Cache ──")
            if "cache" not in sg_ids:
                print("  ERROR: Cache security group not found. Run --step sg first.")
                continue
            cache_endpoint = setup_cache(session, vpc_id, sg_ids["cache"], dry_run=args.dry_run)
            print()

            # Written here — not after the whole loop — because "ec2-setup"
            # (which pushes var/django.conf to each node) can run later in
            # this same loop and needs the file to exist with fresh
            # DB/cache endpoints in it first.
            if db_endpoint and cache_endpoint and not args.dry_run:
                write_django_conf(region, db_endpoint, cache_endpoint)
            elif db_endpoint and cache_endpoint:
                print(f"  [dry-run] Would write DB/cache/token settings to {DJANGO_CONF}")

        elif step == "ec2":
            print("── Step 5: EC2 Instance(s) ──")
            if "node" not in sg_ids:
                print("  ERROR: Node security group not found. Run --step sg first.")
                continue
            key_name = PROJECT
            nodes = setup_ec2(session, region, vpc_id, sg_ids["node"], key_name, dry_run=args.dry_run)
            print()

        elif step == "cert-bucket":
            print("── Step 6: Cert Sync Bucket ──")
            cert_bucket = setup_cert_bucket(session, dry_run=args.dry_run)
            print()

        elif step == "nlb":
            print("── Step 7: Network Load Balancer ──")
            if not nodes:
                nodes = _find_nodes(session)
            if not nodes:
                print("  ERROR: No node(s) found. Run --step ec2 first.")
                continue
            setup_nlb(session, vpc_id, nodes, dry_run=args.dry_run)
            print()

        elif step == "bake-ami":
            print("── Step 8: Bake Golden AMI ──")
            bake_ami(session, region, dry_run=args.dry_run)
            print()

        elif step == "ec2-setup":
            print("── Step 9: EC2 Environment Setup ──")
            setup_ec2_environment(session, region, cert_bucket=cert_bucket, dry_run=args.dry_run)
            print()

        elif step == "ses":
            print("── Step 10: SES Email ──")
            setup_ses(session, region, dry_run=args.dry_run)
            print()

        elif step == "github-secret":
            print("── Step 11: GitHub Actions Secret ──")
            ensure_github_secret(dry_run=args.dry_run)
            print()

        elif step == "verify":
            print("── Step 12: Verify ──")
            verify_deployment(session, region, dry_run=args.dry_run)
            print()

    print("  Done! Run `python aws/deploy.py --status` to check infrastructure.")


if __name__ == "__main__":
    main()

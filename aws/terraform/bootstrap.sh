#!/usr/bin/env bash
# Create the OpenTofu/Terraform state backend for one AWS account.
#
# AUTHORITY: this is step zero of the SECOND provisioner. A django-mojo
# installation is portal-owned by default (INFRASTRUCTURE_MODE unset = managed,
# the admin portal creates and changes AWS resources directly); the OpenTofu
# root beside this file is the INFRASTRUCTURE_MODE = "external" path, and an
# environment has exactly one owner. If you have not decided that OpenTofu owns
# this estate, you do not need a state bucket yet. See README.md, "Who owns
# this environment".
#
# Chicken-and-egg: state has to live somewhere before the first `tofu init`, so
# this is plain AWS CLI rather than Terraform. Run it once per account, before
# anything else. It is idempotent — re-running against an existing bucket and
# table changes nothing.
#
#     ./bootstrap.sh --region us-east-1
#     ./bootstrap.sh --region us-west-2 --profile staging
#
# Then init an environment against it:
#
#     tofu init \
#       -backend-config=bucket=mojo-tfstate-<account-id> \
#       -backend-config=key=<project>/<env>.tfstate \
#       -backend-config=region=<region> \
#       -backend-config=dynamodb_table=mojo-tfstate-lock

set -euo pipefail

REGION=""
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)  REGION="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$REGION" ]]; then
    echo "--region is required" >&2
    exit 2
fi

AWS=(aws --region "$REGION")
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

ACCOUNT=$("${AWS[@]}" sts get-caller-identity --query Account --output text)
BUCKET="mojo-tfstate-${ACCOUNT}"
TABLE="mojo-tfstate-lock"

echo "account : ${ACCOUNT}"
echo "region  : ${REGION}"
echo "bucket  : ${BUCKET}"
echo "table   : ${TABLE}"
echo

# ── state bucket ─────────────────────────────────────────────────────────────

if "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "==> bucket exists"
else
    echo "==> creating bucket"
    # us-east-1 is the one region where CreateBucket rejects a location
    # constraint naming itself.
    if [[ "$REGION" == "us-east-1" ]]; then
        "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
        "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" \
            --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
fi

# Versioning is not optional here. State is the only record of what exists; a
# corrupt or truncated write with no previous version is an afternoon of
# reconciling reality against nothing.
echo "==> versioning"
"${AWS[@]}" s3api put-bucket-versioning \
    --bucket "$BUCKET" --versioning-configuration Status=Enabled

echo "==> encryption"
"${AWS[@]}" s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# State contains generated passwords and resource inventory. There is no version
# of this bucket that should ever be public.
echo "==> public access block"
"${AWS[@]}" s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

# ── lock table ───────────────────────────────────────────────────────────────

if "${AWS[@]}" dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
    echo "==> lock table exists"
else
    echo "==> creating lock table"
    "${AWS[@]}" dynamodb create-table \
        --table-name "$TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST >/dev/null
    "${AWS[@]}" dynamodb wait table-exists --table-name "$TABLE"
fi

cat <<EOF

Done. Initialise an environment with:

  tofu init \\
    -backend-config=bucket=${BUCKET} \\
    -backend-config=key=<project>/<env>.tfstate \\
    -backend-config=region=${REGION} \\
    -backend-config=dynamodb_table=${TABLE}
EOF

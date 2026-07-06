#!/usr/bin/env python
"""
Push SES DNS records to GoDaddy in one shot.

Usage:
  python aws/setup_dns.py --key KEY                 # Key only (newer GoDaddy accounts)
  python aws/setup_dns.py --key KEY --secret SEC    # Key + secret (older accounts)
  python aws/setup_dns.py --dry-run                 # Show what would be added
  python aws/setup_dns.py --status                  # Check current DNS records

Requires: GoDaddy API key from https://developer.godaddy.com/keys
  - Use "Production" environment when creating the key
  - Some accounts have key + secret, newer ones are key-only
"""
import argparse
import json
import os
import sys

# Add parent dir so we can import deploy helpers
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

GODADDY_API = "https://api.godaddy.com/v1"


def _get_domain():
    """Read domain from var/deploy.json, fall back to DOMAIN env var."""
    conf_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "var", "deploy.json")
    if os.path.exists(conf_path):
        with open(conf_path) as f:
            data = json.load(f)
        if data.get("DOMAIN"):
            return data["DOMAIN"]
    return os.environ.get("DOMAIN", "example.com")


DOMAIN = _get_domain()


def load_godaddy_keyfile():
    """Load key/secret from ~/.godaddy_key (KEY=xxx / SECRET=xxx format)."""
    keyfile = os.path.expanduser("~/.godaddy_key")
    if not os.path.exists(keyfile):
        return None, None
    vals = {}
    with open(keyfile) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip()
    return vals.get("KEY"), vals.get("SECRET")


def get_godaddy_creds(args):
    """Get GoDaddy API credentials from args, env, keyfile, or prompt."""
    key = args.key or os.environ.get("GODADDY_KEY")
    secret = args.secret or os.environ.get("GODADDY_SECRET")
    if not key:
        file_key, file_secret = load_godaddy_keyfile()
        if file_key:
            key = file_key
            secret = secret or file_secret
    if not key:
        key = input("  GoDaddy API Key: ").strip()
    if not secret:
        secret = input("  GoDaddy API Secret: ").strip()
    return key, secret


def godaddy_request(method, path, key, secret, data=None):
    """Make a GoDaddy API request."""
    import urllib.request
    import urllib.error

    url = f"{GODADDY_API}{path}"
    # Newer GoDaddy accounts use key-only auth, older ones use key:secret
    auth = f"sso-key {key}:{secret}" if secret else f"sso-key {key}"
    headers = {
        "Authorization": auth,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"  ERROR {e.code}: {body}")
        return None


def get_ses_records(session, region):
    """Fetch current SES verification/DKIM tokens from AWS."""
    ses = session.client("ses")

    # Domain verification token
    attrs = ses.get_identity_verification_attributes(Identities=[DOMAIN])
    v_token = attrs["VerificationAttributes"].get(DOMAIN, {}).get("VerificationToken", "")

    # DKIM tokens
    dkim_attrs = ses.get_identity_dkim_attributes(Identities=[DOMAIN])
    dkim_tokens = dkim_attrs["DkimAttributes"].get(DOMAIN, {}).get("DkimTokens", [])

    records = []

    # TXT record for domain verification
    if v_token:
        records.append({
            "type": "TXT",
            "name": f"_amazonses",
            "data": v_token,
            "ttl": 600,
        })

    # 3 CNAME records for DKIM
    for token in dkim_tokens:
        records.append({
            "type": "CNAME",
            "name": f"{token}._domainkey",
            "data": f"{token}.dkim.amazonses.com",
            "ttl": 600,
        })

    # MAIL FROM records
    records.append({
        "type": "MX",
        "name": "mail",
        "data": f"feedback-smtp.{region}.amazonses.com",
        "ttl": 600,
        "priority": 10,
    })
    records.append({
        "type": "TXT",
        "name": "mail",
        "data": "v=spf1 include:amazonses.com ~all",
        "ttl": 600,
    })

    return records


def show_records(records):
    """Print the DNS records that will be added."""
    for r in records:
        print(f"    {r['type']:6s}  {r['name']}.{DOMAIN}  →  {r['data']}")


def push_records(records, key, secret, dry_run=False):
    """Push all DNS records to GoDaddy via PATCH (adds/updates without deleting existing)."""
    if dry_run:
        print(f"\n  [dry-run] Would add {len(records)} DNS records to {DOMAIN}:")
        show_records(records)
        return True

    print(f"\n  Pushing {len(records)} DNS records to {DOMAIN}...")
    show_records(records)
    print()

    # GoDaddy PATCH endpoint adds records without replacing existing ones
    # Group by type since GoDaddy API wants records grouped
    by_type = {}
    for r in records:
        by_type.setdefault(r["type"], []).append(r)

    success = True
    for rtype, recs in by_type.items():
        payload = []
        for r in recs:
            entry = {"type": rtype, "name": r["name"], "data": r["data"], "ttl": r["ttl"]}
            if rtype == "MX":
                entry["priority"] = r.get("priority", 10)
            payload.append(entry)

        result = godaddy_request(
            "PATCH",
            f"/domains/{DOMAIN}/records",
            key, secret,
            data=payload,
        )
        if result is None:
            print(f"  ✗ Failed to add {rtype} records")
            success = False
        else:
            print(f"  ✓ {rtype} records added ({len(recs)})")

    return success


def show_status(key, secret):
    """Show current DNS records for the domain."""
    print(f"\n  Current DNS records for {DOMAIN}:\n")

    # Fetch all records
    records = godaddy_request("GET", f"/domains/{DOMAIN}/records", key, secret)
    if not records:
        return

    # Filter to SES-related records
    ses_related = []
    for r in records:
        name = r.get("name", "")
        data = r.get("data", "")
        if any(kw in name or kw in data for kw in ["_amazonses", "_domainkey", "amazonses.com", "dkim"]):
            ses_related.append(r)
        elif name == "mail":
            ses_related.append(r)

    if ses_related:
        print(f"  SES-related records:")
        for r in ses_related:
            print(f"    {r['type']:6s}  {r['name']}.{DOMAIN}  →  {r['data']}")
    else:
        print(f"  No SES-related records found")

    print(f"\n  Total records: {len(records)}")


def main():
    parser = argparse.ArgumentParser(description="Push SES DNS records to GoDaddy")
    parser.add_argument("--key", help="GoDaddy API key")
    parser.add_argument("--secret", help="GoDaddy API secret")
    parser.add_argument("--region", default="us-west-2", help="AWS region (default: us-west-2)")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be added")
    parser.add_argument("--status", action="store_true", help="Show current DNS records")
    args = parser.parse_args()

    key, secret = get_godaddy_creds(args)
    if not key:
        print("  ERROR: GoDaddy API key required")
        print("  Get yours at: https://developer.godaddy.com/keys")
        sys.exit(1)

    if args.status:
        show_status(key, secret)
        return

    # Load AWS creds for SES lookup
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from deploy import load_credentials, get_boto_session
    creds = load_credentials()
    session = get_boto_session(args.region, creds)

    records = get_ses_records(session, args.region)
    if not records:
        print("  No SES records found. Run `python aws/deploy.py --step ses` first.")
        sys.exit(1)

    success = push_records(records, key, secret, dry_run=args.dry_run)

    if success and not args.dry_run:
        print(f"\n  ✓ All records pushed to GoDaddy")
        print(f"  DNS propagation may take a few minutes.")
        print(f"  Re-run `python aws/deploy.py --step ses -y` to check verification status.")


if __name__ == "__main__":
    main()

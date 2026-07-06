# Provisioning

First-time AWS infra setup is `aws/deploy.py` — security groups, Aurora
PostgreSQL, ElastiCache Valkey, EC2 instance(s), and (for the `high` volume
tier) a Network Load Balancer. Read the module docstring at the top of
`aws/deploy.py` for the full config schema, volume tiers, and multi-node
phasing — it's kept current there rather than duplicated here.

Quick start:

```bash
# hand-write var/deploy.json (copy aws/deploy.example.json) or:
python aws/deploy.py --init      # interactive wizard

python aws/deploy.py             # provision everything var/deploy.json describes
python aws/deploy.py --status    # check what's already provisioned, safe to re-run anytime
```

The script is resilient to re-running: existing resources are detected
(singleton, or by `{PROJECT}-` prefix match if more than one exists) and left
alone rather than recreated.

## After provisioning: first-time HTTPS

`aws/ec2_deploy.sh` installs an nginx config with a `listen 443 ssl` block
pointed at a self-signed placeholder cert, so nginx can start cleanly before
a real certificate exists. Once DNS for your domain points at the node's
Elastic IP, get the real cert with:

```bash
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
```

Certbot rewrites the `ssl_certificate`/`ssl_certificate_key` lines to the
real `/etc/letsencrypt/live/...` paths in place — no manual nginx editing
needed.

## Verifying connectivity

Before running migrations on a freshly provisioned node, confirm DB/cache
connectivity:

```bash
python3 bin/manage.py status --timeout 5
```

This should return in under a second or two. If it hangs well past the
timeout you asked for, that's a strong signal of a silent network-level
block — most likely a security group rule with the wrong port or the wrong
source group, not an application-level problem (a real refusal or auth
failure fails fast; a dropped-packet SG mismatch just hangs). Check
`aws/deploy.py --status` for the security groups actually in play and verify
their inbound rules against the ports the app really uses (5432 for
Postgres, 6379 for Valkey).

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
needed. **This is the single-node instruction only** — see "Multi-node
certificates" below before running it on a fleet.

Certbot lives in its own virtualenv at `/opt/certbot`, symlinked to
`/usr/local/bin/certbot` (and `/usr/bin/certbot`). It shares no packages with
the application, so pinning a project dependency can never break renewal — a
newer `cryptography` co-installed with certbot is enough to break its
pyOpenSSL, and `certbot renew --quiet` then fails silently until the
certificate expires. Confirm it after provisioning:

```bash
certbot --version
```

One residual: `aws/certbot_sync.py` still runs under the *system* `python3`,
because it needs `boto3` (which arrives with `django-mojo`). The venv isolates
certbot from the app, not the sync script — a project pin that breaks `boto3`
still breaks certificate sync.

## Multi-node certificates

On a fleet, exactly one node — `PRIMARY_BALANCER_HOST`, which is node 1 —
holds the ACME listener, renews, and publishes the lineage to S3. Every other
node pulls it. The whole plane is armed by three keys in `var/django.conf`,
which `aws/deploy.py` writes into its managed block whenever `EC2_COUNT > 1`:

```
LOAD_BALANCER_DOMAIN = "yourdomain.com"
PRIMARY_BALANCER_HOST = "yourproject-node1"
AWS_CERT_BUCKET = "yourproject-certs"
```

`aws/certbot_sync.py` reads them from that file (plain `key = value`), never
from `var/ops.json` — `ops.json` is an operator-reference copy that nothing
reads. Absent the keys, sync and primary-gating stay dormant and a node
behaves exactly like a single-node box.

**Scaling out (Phase 3)** — bump `EC2_COUNT` in `var/deploy.json`, then:

```bash
python aws/deploy.py               # a BARE full run, not --step ec2/--step nlb
python aws/deploy.py --step verify
```

The full run is what actually delivers the fleet: every step is get-or-create,
so re-running is cheap, and only the full run re-derives the DB/cache
endpoints (which is what lets it rewrite `var/django.conf`, now fleet-shaped),
creates the cert bucket, launches the new nodes from `CUSTOM_AMI_ID`,
registers them with the NLB, and pushes the conf to *every* node. `--step ec2`
plus `--step nlb` do none of the conf, push, or bucket work, so a fleet scaled
out that way can never arm cert sync.

**Issuing the fleet certificate** — on the primary only:

```bash
sudo certbot certonly --webroot -w /var/www/certbot -d yourdomain.com
```

then point the two `ssl_certificate*` lines in the vhost at
`/etc/letsencrypt/live/yourdomain.com/`. Do **not** use `--nginx` on a fleet:
besides rewriting those lines it injects `include
/etc/letsencrypt/options-ssl-nginx.conf`, and that file exists only where
certbot ran. The moment the vhost reaches a replica, `nginx -t` fails there
and the node serves nothing. The shipped vhosts keep their TLS settings
self-contained for exactly this reason.

**The two crons**, both installed by `aws/ec2_deploy.sh`:

| Cron | Runs | Does |
|---|---|---|
| `1_certbot` | daily, 08:30 | `certbot_sync.py --renew` — renews, then pushes |
| `4_certbot_sync` | every 5 min | `certbot_sync.py` — pulls on replicas, publishes on the primary |

`--renew` is role-aware. An unconfigured box renews itself exactly as before.
On a configured fleet only the primary renews, and it pushes the fresh
certificate in the same run rather than waiting for the next tick; replicas
skip, because they hold regular files pulled from S3 rather than certbot's
symlinks into `archive/`, and certbot renewing against one of those would
corrupt it. Every invocation logs one line to
`var/logs/certbot_sync.log` — success included. Treat that log as the
liveness signal: the old cron ran `--quiet` and said nothing either way, so a
broken certbot looked exactly like a healthy one for the forty days it took
the certificate to expire.

Two behaviors worth knowing before they surprise you:

- A node with `AWS_CERT_BUCKET` set but `PRIMARY_BALANCER_HOST` missing
  **refuses to renew** (exit 1, logged) rather than guessing. That is
  deliberate: renewing on a node that might be a replica is the corruption
  this design exists to prevent. The tradeoff is real — a mis-edited conf
  stops renewal — so fix the conf; there is no fallback renew. The refusal is
  visible in the heartbeat log, and the sync path already refuses the same
  state the same way.
- Dropping `EC2_COUNT` back to `1` and re-running removes the three keys from
  the managed block, which disarms sync fleet-wide. Correct, but not subtle.

**Existing nodes** pick all of this up by re-running `sudo bash
aws/ec2_deploy.sh` on each one — that is what rewrites the crons. There is no
cron-convergence plane; the crons are written at provisioning time. A box
provisioned before the `/opt/certbot` venv existed also needs that block run
by hand (see the "Certbot, in its own venv" section of `aws/ec2_bootstrap.sh`).

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

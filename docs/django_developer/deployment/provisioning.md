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
needed. **This is the single-node instruction only** — see "Fleet
certificates, via dnsman + edge" below before running it on more than one box.

Renewal is `/etc/cron.d/1_certbot`, daily at 08:30, logging to
`var/logs/certbot.log`. It is deliberately not `--quiet`: a silent renew cron
makes a broken certbot look exactly like a healthy one for the forty days it
takes the certificate to expire, so treat that log as the liveness signal.

Certbot lives in its own virtualenv at `/opt/certbot`, symlinked to
`/usr/local/bin/certbot` (and `/usr/bin/certbot`). It shares no packages with
the application, so pinning a project dependency can never break renewal — a
newer `cryptography` co-installed with certbot is enough to break its
pyOpenSSL, and `certbot renew --quiet` then fails silently until the
certificate expires. Confirm it after provisioning:

```bash
certbot --version
```

## Fleet certificates, via dnsman + edge

On a fleet, no node issues certificates and no node copies them to another
node. **dnsman** issues and renews them centrally over ACME DNS-01 (the ACME
account key is held in KMS, never on a box), and **`mojo.apps.edge`** is the
node-side plane: it asks "what should I be serving?", renders the answer into a
new generation under `EDGE_ROOT`, validates it against this node's real nginx
configuration, and swaps a symlink.

The KMS side is a hard prerequisite: dnsman's `AcmeAccount` and `Certificate`
are `KSMSecrets` models, and KSMSecrets raises a `RuntimeError` at first use
unless the `KMS_KEY_ID` setting is configured. `aws/deploy.py` provisions the
key (`--step kms`, alias `alias/<project>-secrets`) and writes `KMS_KEY_ID`
into `var/django.conf`'s managed block on a full run; a deployment provisioned
before that step existed can run `python aws/deploy.py --step kms` once and add
the printed key id to its conf. Nothing is pulled from S3, there is no
primary and no replica, and a node that was switched off converges on its next
sweep.

Design docs live in django-mojo:
[`edge/README.md`](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/edge/README.md)
and
[`dnsman/Certificates.md`](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/dnsman/Certificates.md).

> **Migrating a fleet that still runs certbot_sync-over-S3: read this first.**
> Do **not** adopt post-1611 `aws/deploy.py` or `aws/ec2_deploy.sh` into a fleet
> whose certificates still come from the S3 sync plane. Both have had the cert
> plane removed: a re-synced `deploy.py` run rewrites `var/django.conf`'s
> managed block *without* `LOAD_BALANCER_DOMAIN`, `PRIMARY_BALANCER_HOST` and
> `AWS_CERT_BUCKET`, and the legacy `certbot_sync.py` on those nodes then finds
> itself unconfigured and returns 0 at DEBUG — the pull goes dormant **silently**
> and certificates expire weeks later with nothing visibly broken. Install edge
> on every node, verify `installed.json` fleet-wide, and only then move the
> tooling over.

### The four node prerequisites

Three of the four are provisioned by `aws/ec2_deploy.sh`, so a node built after
this change is ready and only needs the settings flipped:

| Prerequisite | Provisioned by | Notes |
|---|---|---|
| `mojo.apps.dnsman` in `apps.json` + its 3 migrations | you, at opt-in | dnsman is not installed by default |
| `/etc/sudoers.d/mojo-edge` | `ec2_deploy.sh` from `aws/nginx/sudoers.d/mojo-edge` | installed 0440 root:root, after `visudo -cf` passes |
| `/etc/nginx/conf.d/mojo.conf` | `ec2_deploy.sh`, via the existing `conf.d/` copy | one line: `include /opt/api/var/edge/current/conf.d/*.conf;` |
| `EDGE_ROOT` (`/opt/api/var/edge`), ec2-user-owned | `ec2_deploy.sh` | the job engine that runs the installer is ec2-user |

The sudoers file grants exactly two **argument-less absolute-path** commands:
`/usr/sbin/nginx -t` and `/usr/bin/systemctl reload nginx`.

- **Never add a rule for the staged check.** `nginx -t -c <an app-writable
  path>` makes that file nginx's *main* configuration, where `load_module` is
  legal and is `dlopen()`ed as the user running the check — that is arbitrary
  root code, not a config test. The staged check runs unprivileged by design
  (`EDGE_NGINX_STAGED_TEST_CMD`). The live-config `sudo nginx -t` is not
  vulnerable to the same trick: `conf.d/*.conf` is included inside `http {}`
  (`aws/nginx/nginx.conf`), and `load_module` is main-context-only, so an
  edge-written file carrying one fails `nginx -t` with "directive is not
  allowed here" and nothing is loaded.
- **Honesty about what this grant buys today: nothing.** AL2023's cloud-init
  ships `ec2-user ALL=(ALL) NOPASSWD:ALL` and nothing in this skeleton removes
  it, so on today's node shape ec2-user is already root-equivalent. The file is
  the documented narrow interface the installer needs, and it is what survives
  the day the blanket grant is dropped or the engine runs as a dedicated user.
  Dropping that blanket grant is a separate security decision, deliberately not
  made here.

**The var permission sweep excludes `var/edge`.** Edge generations hold private
keys at 0600 inside 0700 directories; the sweep's 2775/0664 would hand every
one of them to the `www` group, which is the account nginx and uvicorn run as.
Both `find` lines in `ec2_deploy.sh` carry `-path "${PROJ_PATH}/var/edge"
-prune -o` for that reason (`-not -path "*/edge/*"` does not work — it still
matches `var/edge` itself). The `chown -R ec2-user:www` needs no exclusion:
edge files are already ec2-user-owned and at 0600/0700 the group bits grant
nothing whatever group is named.

### The setting that turns it on

In `config/settings/prod/__init__.py`:

```python
EDGE_CONVERGE_ENABLED = True
```

That is the whole switch. Earlier revisions also required
`EDGE_RESERVED_SERVER_NAMES`, a fail-closed reservation list protecting the
platform's own hostnames from vhost shadowing. That gate was retired upstream
(edge migration `0005_remove_vhost_claims_reserved`): naming a vhost is now
authorized per-domain — Domain ownership plus the `manage_dns` permission —
so the setting no longer exists and nothing needs declaring here.

### The operator flow

1. Add the domain in dnsman (and seed its `DnsCredential`).
2. Add the `_acme-challenge` CNAME once, if the zone is one we do not hold API
   credentials for. It must stay there forever.
3. Request the certificate. Wildcards are the norm, so one request covers every
   subdomain.
4. Declare the upstream, then create the vhost.

### What happens without touching a node

| Trigger | Effect |
|---|---|
| `install_generation` | broadcast to the pool; every node installs immediately |
| `converge_edge` | a sweep every 10 minutes catches anything that missed the broadcast |
| `certificate_updated` | fires on renewal; the new material rides the next generation |

### Where to look when it does not

- `EDGE_ROOT/installed.json` — the generation this node believes it is on, and
  any excluded vhosts.
- `EDGE_ROOT/current` — the symlink; `ls -l` tells you which generation is live.
- The incident stream — a tenant whose certificate material was unfetchable is
  excluded and reported rather than freezing the whole pool.

### Two coupling notes

- **With convergence ON, code deploys are gated on the live nginx config.**
  `post_deploy.sh` runs `nginx -t || die`, and the live config now includes
  edge generations. The installer validates before it installs, so only drift
  between the staged and live environments can bite — but that is the failure
  mode to look for if a deploy dies at the nginx test.
- **The prerequisites land at provisioning time only.** `post_deploy.sh` does
  not distribute `conf.d/`, and there is no cron-convergence plane. A node
  provisioned before this change needs `sudo bash aws/ec2_deploy.sh` re-run (or
  the three items installed by hand) before it can opt in. A box provisioned
  before the `/opt/certbot` venv existed also needs that block run by hand (see
  the "Certbot, in its own venv" section of `aws/ec2_bootstrap.sh`).

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

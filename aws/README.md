# AWS infrastructure — operator guide

**If you are a backup admin and something is on fire, start here.**

This describes how a django-mojo project runs on AWS: what the pieces are, how
to do the common jobs, and what to check when something breaks. It describes the
**target** setup. Anything not built yet is marked **[PLANNED]** — treat those
sections as the intended design, not as something you can run today.

Design reasoning and rejected alternatives live in
[`docs/django_developer/multi_node_deployment_plan.md`](../docs/django_developer/multi_node_deployment_plan.md).
This file is the *how*; that file is the *why*.

---

## 1. The shape of it

```
        the internet
             │
    ┌────────▼─────────┐   two fixed IP addresses that never change.
    │  network load    │   Every domain's DNS points here.
    │  balancer (NLB)  │
    └────────┬─────────┘
             │  passes traffic through without decrypting it
   ┌─────────┴─────────┐
   │                   │
┌──▼───┐           ┌───▼──┐   identical machines, built from one image.
│node 1│           │node 2│   Any one can be destroyed and rebuilt.
└──┬───┘           └───┬──┘   nginx handles TLS, hands off to the Django app.
   └─────────┬─────────┘
             │
   ┌─────────┴──────────┐
   │  Aurora PostgreSQL │  writer + reader, encrypted, in private subnets
   │  Valkey (Redis)    │  primary + replica
   └────────────────────┘
```

**The nodes hold no data.** Everything that matters is in the database, the
cache, or S3. That is what makes "throw a node away and start another" safe, and
it is the rule to protect — if you ever find yourself wanting to keep something
important only on a node's disk, stop and put it somewhere else.

Environments are named `<project>-<env>`, e.g. `wmx-prod`, `wmx-staging`.
Production and staging currently share one AWS account, separated by region.

---

## 2. Standing up a new environment

Everything is described in Terraform (we use OpenTofu; the files work with
either). One file per environment describes the whole thing.

```bash
cd aws/terraform

# once per AWS account — creates somewhere to keep Terraform's state
./bootstrap.sh --region us-east-1

# once per environment
tofu init \
  -backend-config=bucket=mojo-tfstate-<account-id> \
  -backend-config=key=<project>/<env>.tfstate \
  -backend-config=region=us-east-1 \
  -backend-config=dynamodb_table=mojo-tfstate-lock

cp envs/example.prod.tfvars envs/<project>.prod.tfvars
# edit it: project name, region, size, ssh key name

tofu plan  -var-file=envs/<project>.prod.tfvars    # READ THIS before applying
tofu apply -var-file=envs/<project>.prod.tfvars
```

`tofu plan` shows exactly what will change before anything happens. **Always read
it.** If it says it will destroy something you did not expect it to destroy,
stop.

### Sizing

One word controls capacity:

| `size` | nodes | database | cache |
|---|---|---|---|
| `micro` | 1 | writer only | 1 node |
| `small` | 2 | writer + 1 reader | 2 nodes |
| `medium` | 4 | writer + 2 readers | 2 bigger nodes |
| `large` | 6 | bigger writer + 2 readers | 3 bigger nodes |

Going from `small` to `medium` is safe to do on a live system — it only adds
machines. Going to `large` changes machine *types*, which requires restarting
things one at a time; see the plan document.

### After Terraform finishes

```bash
tofu output -raw django_conf_fragment   # paste into var/django.conf
tofu output -raw db_password            # the database password
tofu output point_dns_at                # the IPs your domains point at
```

Then §4 to get a certificate, and the site is live.

---

## 3. Adding a domain

Every brand or tenant domain follows the same three steps.

**Step 1 — point the domain at us.** In whatever DNS the domain uses, two A
records, one per NLB IP address (`tofu output point_dns_at`).

**Step 2 — let us prove we own it.** One CNAME record, added once, never changed:

```
_acme-challenge.<their-domain>   CNAME   <label>.acme.<our-acme-zone>
```

This is how we get certificates without needing a login to their DNS. **It must
stay there forever** — if it is deleted, certificates stop renewing about two
months later and the site goes down with an expired-certificate warning.

**Step 3 — add it in the admin portal.** DNS → Certificates → request. The
certificate is issued, stored in the database, and every node picks it up.

**[PLANNED]** Steps 2 and 3 depend on dnsman's CNAME delegation, which is being
built. Until then certificates are issued by certbot on one designated machine —
see §8.

### Why one CNAME covers many subdomains

We request wildcard certificates. One certificate for `example.com` and
`*.example.com` covers `api.example.com`, `portal.example.com`, and anything else
you add later — with no further DNS changes.

---

## 4. Getting the first certificate on a brand-new environment **[PLANNED]**

A new environment has no certificate, and the admin portal needs one. This is not
a deadlock, because of *how* we prove domain ownership: we do it through DNS, not
by having someone connect to the server. Nothing needs to reach the box.

```bash
# on the node, once
manage.py dnsman_bootstrap --domain <your-domain> --wildcard --install
```

That issues the certificate, writes it to disk, and reloads nginx. The portal is
then reachable and everything else is done through it.

The machine image ships a self-signed placeholder certificate so nginx starts and
serves *something* before this runs. A browser warning at that stage is expected.

---

## 5. Deploying

**[PLANNED — the multi-node parts]**

Four things get deployed, and they are independent:

| What | How it gets there |
|---|---|
| Application config (`django.conf`) | published to S3; each node pulls it |
| Website builds | CI uploads to S3; each node pulls |
| Certificates and nginx vhosts | issued centrally; each node pulls |
| API code | a release is published; nodes are updated one at a time |

**The rule underneath all four:** each node checks for updates on a timer, so a
node that was switched off, or that missed a message, catches up by itself. The
deploy "button" only makes it happen sooner — it is never the thing that
guarantees it happened.

That is why a node that has been down for a day fixes itself when it comes back,
and why a brand-new node is correct as soon as it boots.

### Database migrations

Migrations run automatically on every deploy, on one machine only, protected by a
database lock so two cannot run at once. **If a migration fails, the deploy stops
and nothing else is updated.** That is deliberate — half-deployed is worse than
not deployed.

---

## 6. Routine jobs

**Change a setting or rotate a key**
Edit the published `django.conf` in S3. Nodes pick it up within a couple of
minutes. Do not edit it on a node — your change will be overwritten.

**Add capacity**
Change `size` in the environment's `.tfvars`, run `tofu plan`, read it, apply.

**Replace a broken node**
`tofu taint` the instance and apply. It rebuilds from the image and pulls
everything it needs. Nothing on a node is irreplaceable.

**Get into a box**
SSH with the admin key. Logins are rare by design and are alerted on — if you get
an alert about a login that was not you, treat it as an incident.

---

## 7. When something breaks

**The site is down**
Check the load balancer's target health first. It tells you whether the nodes are
failing their health check (a problem on the nodes) or whether traffic is not
arriving at all (DNS or the load balancer).

**One node is unhealthy, the rest are fine**
Traffic has already stopped going to it. Nothing is on fire. Look at
`/opt/api/var/logs/` on that node, and at whether its sync scripts have been
failing.

**A certificate expired**
Something stopped renewing weeks ago and the alarm was missed or not built. Check
that the `_acme-challenge` CNAME for that domain still exists — the most common
cause is someone tidying up DNS records.

**A deploy "worked" but the change is not live**
Check whether every node actually got it. The whole point of the timer-based
design is that a node fixes itself, so a node stuck on old code is usually a node
that cannot reach S3 — check its credentials and its outbound network.

**Something changed and nobody knows who**
CloudTrail records every AWS action. **[PLANNED]** — not enabled yet, which is
itself worth fixing.

---

## 8. Honest status

Do not assume anything here is running. As of this writing:

**Built and tested**
- Terraform for the whole environment (network, load balancer, nodes, database,
  cache, alarms)
- `certbot_sync.py` — copies one certificate between machines, and (via
  `--renew`) gates renewal so only the primary runs certbot *(the pull half
  could never install on Amazon Linux 2023 until this was fixed: it staged
  downloads in `/tmp`, which is a RAM filesystem there, so the rename into
  `/etc/letsencrypt` was refused every single time)*
- `config_sync.py` — pulls `django.conf` from S3 *(the script works; nothing
  installs it yet)*

**Not built**
- Website and API code sync, the rolling deploy, dnsman certificates, the
  first-certificate bootstrap, CloudTrail, the certificate-expiry alarm

**Known problems in the current single-machine setup**
- The deploy script ignores failures — a failed migration or dependency install
  is reported as success
- Nothing is monitored; there are no alarms
- The machine has never been backed up
- The database is not encrypted, and that can only be fixed by creating a new one

---

## 9. Where things are

| | |
|---|---|
| `aws/terraform/` | the whole environment as code |
| `aws/terraform/envs/` | one file per environment |
| `aws/*.sh`, `aws/*.py` | scripts that run on the machines |
| `aws/nginx/` | web server config |
| `aws/check_setup.py` | audits a live AWS account against this design |
| `docs/django_developer/multi_node_deployment_plan.md` | why it is built this way |

Start with `./aws/check_setup.py` if you have inherited an environment and do not
know what state it is in. It is read-only and will not change anything.

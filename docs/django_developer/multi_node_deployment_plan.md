# Multi-node deployment — proposed design

**Status:** proposal, not built. Seeking review before implementation.
**Date:** 2026-08-06
**Scope:** django-mojo-skeleton (and every project cloned from it)

---

## 1. What problem this solves

Today a django-mojo project runs on **one EC2 box**. Deploying means SSH to that
box, `git pull`, restart. That works and is simple.

We are moving to **2–6 identical nodes behind a network load balancer**. The
moment there is more than one node, "SSH in and pull" stops working, and four
separate things need to reach every node:

| # | Payload | Example of it changing |
|---|---|---|
| 1 | **Application config** (`var/django.conf`) | rotate an API key |
| 2 | **nginx vhosts + TLS certificates** | onboard a new tenant domain |
| 3 | **Static website builds** (`/opt/www/<project>`) | a web dev pushes to main |
| 4 | **API code** (`/opt/api`) | we ship a feature |

This document proposes one coherent way to handle all four, without downtime.

### The topology being deployed onto

Assumed throughout, and already built in `aws/terraform/`:

```
tenant DNS ──A──▶ NLB static IPs
                   │
                   ├── :443 TCP ──▶ every node        (player + API traffic)
                   └── :80  TCP ──▶ ONE node only     (Let's Encrypt challenges)
                                     "the gatekeeper"

each node: nginx (terminates TLS) ──▶ uvicorn ──▶ Aurora + Valkey
           all nodes identical, built from one AMI
```

The load balancer passes TCP through without decrypting, so **each node holds
its own copy of the TLS certificates**. Port 80 is pointed at exactly one node
so that Let's Encrypt's HTTP-01 challenge always lands where certbot is running;
that node then distributes the certificate to the others. We call it the
**gatekeeper**.

---

## 2. The core principle

> **Timers guarantee that nodes converge. Jobs only make it faster.**

Every payload lands on every node via a small script on a **systemd timer** that
pulls from S3 (or git) and installs if changed. That is the substrate, and it is
what actually guarantees correctness.

django-mojo's job engine can *additionally* fire a message telling nodes to run
that sync **right now**, so a deploy is seconds rather than up to a poll
interval. But the job carries no payload and does no work — it only says "check
now."

**Why the job engine must not be responsible for deployment:**

1. **It is part of the thing being deployed.** Ship broken API code through the
   job engine and you have broken the mechanism that ships the fix.
2. **A node whose app is down cannot receive a job.** That is precisely the node
   that most needs to converge. A timer keeps trying; a push does not.
3. **A newly booted node has no code yet**, so it cannot run a job engine to
   fetch code. Pull works at boot; push cannot.

If we get this backwards, the failure mode is a node that silently stops
updating and nobody notices until it serves something stale.

---

## 3. Proposed design, payload by payload

The unifying idea: **each payload has exactly one writer**, and the direction of
travel follows from who that writer is.

| Payload | Who owns it | Direction | Mechanism |
|---|---|---|---|
| `django.conf` | an operator | S3 → every node | `config_sync.py` ✅ built |
| nginx `conf.d` + certs | **the gatekeeper** | gatekeeper → S3 → other nodes | extend `certbot_sync.py` |
| `/opt/www/<project>` | CI (GitHub Actions) | CI → S3 → every node | `www_sync.py` (new) |
| API code | git `origin/main` | git → every node | sequenced deploy job |

### 3.1 Application config — built

`config_sync.py` pulls `django.conf` from S3 on a timer and at boot.

The important safety property: **if the fetch fails, keep the existing file.** A
node with stale config still serves; a node with no config does not start.

Secrets note: reading S3 needs credentials, so one small bootstrap credential
still lives on each node. That is not zero, but it is much better than baking
every secret into the AMI — the remaining key is scoped read-only to a single S3
prefix, and every *other* secret becomes rotatable with an upload. When nodes can
carry an IAM instance profile, that last credential disappears.

### 3.2 nginx vhosts and certificates — extend `certbot_sync.py`

**Why these travel together, and why the gatekeeper owns them.**

`certbot --nginx` *edits vhost files in place* on whichever node runs it — our
existing vhosts carry `# managed by Certbot` comments. So the gatekeeper is
already the authority for `conf.d`, whether we plan for it or not. If we also
published `conf.d` from a hand-managed S3 prefix, there would be two writers
fighting on every renewal.

They must also move **as one payload**, because a vhost referencing
`/etc/letsencrypt/live/<domain>/fullchain.pem` fails `nginx -t` on any node that
has not yet received that certificate. Shipping them together means one
`nginx -t` and one reload, instead of two mechanisms racing.

**Onboarding a new tenant domain then looks like this:**

```
On the gatekeeper:
  1. write /etc/nginx/conf.d/joecasino.xyz.conf
  2. certbot --nginx -d joecasino.xyz
  3. tenant points joecasino.xyz A ──▶ the NLB's static IPs

Automatically, within a minute:
  gatekeeper publishes certs + conf.d to S3
  other nodes pull both, run nginx -t, reload
```

No SSH to other nodes. No infrastructure change. **DNS must point at the NLB
before step 2**, or the challenge cannot reach the gatekeeper.

### 3.3 Website builds — `www_sync.py` (new)

Each web project's GitHub Action currently rsyncs to one box. With N nodes, the
natural instinct is to loop over a node list — but that list goes stale, a node
that is down during a deploy is silently skipped, and a *new* node serves 404s
until the next deploy.

**Invert it.** CI syncs the build to `s3://<bucket>/www/<project>/`. Each node
pulls on a short timer. CI never needs to know how many nodes exist, a node that
was down catches up when it returns, and a new node populates itself at boot —
which is what makes AMI-based scaling actually work.

### 3.4 API code — sequenced deploy job

Code already arrives by `git pull` with deploy keys, which is fine and we would
not change it. What is missing is **sequencing** and **migrations**.

**Sequencing.** django-mojo's job engine already supports box-direct channels:
a channel named `<hostname>-engine` is consumed by exactly that node
(`mojo/apps/jobs/__init__.py:101`). So a rolling deploy is simply: publish to
node 1, wait for it to report done, publish to node 2, and so on. **Ordered
rollout with no new locking primitive** — no Redis semaphore, no leader
election. The sequence is just the order we publish in.

**Migrations — the genuinely hard part.** With N nodes,
`./bin/manage.py migrate` must run **exactly once**, and must finish before any
node runs code that depends on it. This is not solved by orchestration; it is a
discipline:

1. One designated node (the gatekeeper) runs `migrate` before the rolling
   restart begins.
2. Migrations must be **expand/contract**: add nullable columns and new tables
   in the release *before* the code that uses them; drop them in the release
   *after* the code that stopped using them. Never rename or drop a column in
   the same deploy that changes the code using it.

Without (2) there is always a window where old code meets a new schema — and a
rolling deploy guarantees that window exists. This constrains how migrations are
*written*, not just how they are run, so it belongs in the project's model
conventions as a standing rule.

---

## 4. The gatekeeper: recommendation is *not* to build failover

A natural question is whether the gatekeeper should be a dynamic role — elected
in Redis, failed over automatically like an Aurora writer. **We recommend
against it**, for two reasons.

**The load balancer is the real gatekeeper.** Port 80 physically reaches exactly
one node because of target-group membership. Electing a different node in Redis
would not change where Let's Encrypt challenges land. To be meaningful, an
election would also have to modify the AWS target group — a control-plane action
requiring credentials and its own failure modes.

**The urgency does not justify it.** Certificates last 90 days and certbot
retries. Losing the gatekeeper gives us *weeks* to react, not seconds. This is
not a database-writer problem. The correct control is an **alarm when any
certificate is within 21 days of expiry** — that single alarm catches every
underlying cause (gatekeeper down, sync broken, challenge misrouted, permissions
wrong) — plus a documented procedure for re-designating a gatekeeper.

### But there is a real problem worth fixing

The role is currently named in **two places** that must agree:

- `PRIMARY_BALANCER_HOST` in `var/django.conf`, which `certbot_sync.py` compares
  against the hostname to decide publish-vs-pull
- membership of the `certbot-targets` load balancer target group

If they drift, the node receiving challenges decides it is a follower and never
publishes. Certificates quietly stop renewing while everything looks healthy —
discovered up to 90 days later.

**Proposal:** have `certbot_sync.py` *derive* the role instead — one AWS API call
asking "is my instance in the certbot target group?", cached for a few minutes.
Then the target group is the single source of truth, `PRIMARY_BALANCER_HOST`
disappears, and this class of failure becomes impossible. Re-designating a
gatekeeper becomes one target-group edit and nothing else.

That is the change we would make: same static role, no election, but impossible
to get out of sync.

---

## 5. What belongs in django-mojo itself

Deliberately small:

- **Trigger and sequencing** — the deploy job, published box-direct in order.
- **Observability** — each node reporting its deploy outcome as an incident
  event under `system:deploy:*`, so a node that silently failed to converge
  appears on the dashboard instead of being discovered weeks later. Best
  value-for-effort item here, and the one most likely to be skipped.

Deliberately **not** in django-mojo: carrying the payload, or being required for
a node to converge. Those stay with S3 and systemd timers, per §2.

---

## 6. Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| Job engine performs the deploy (not just triggers it) | Circular dependency; cannot reach a node whose app is down; cannot bootstrap a new node. See §2. |
| Shared network filesystem (EFS) for content and certs | Adds a shared mutable failure domain to an architecture whose whole purpose is that no single component takes down the fleet. Content is immutable per release and tiny; certs are already solved. |
| Terminate TLS at the load balancer with AWS ACM certificates | Caps us at 25 certificates per balancer (a hard ceiling for a multi-tenant platform), and requires each tenant to add a validation DNS record that must persist forever or renewals silently stop. |
| Redis-elected gatekeeper with automatic failover | Does not move the load balancer's port-80 target, so it does not actually change where challenges land. See §4. |
| CI pushes directly to every node | Requires a node inventory that goes stale; silently skips nodes that are down; new nodes are not populated. See §3.3. |
| Bake `django.conf` into the AMI | Makes the image a secret-bearing artifact; rotation requires a re-bake; a node from an old AMI boots with old config. |

---

## 7. Open questions — where review is most wanted

These are the points we are least confident about.

1. **Is deriving the gatekeeper role from the AWS target group worth the added
   dependency?** It removes a silent-failure class, but it makes a script that
   runs every minute depend on an AWS API call (cached). The alternative is
   keeping `PRIMARY_BALANCER_HOST` and relying on an audit check to catch drift.

2. **Should the API-code deploy use git pull or S3 artifacts?** Git is what
   exists and needs no new machinery, but it means a deploy depends on GitHub
   being reachable from every node, and two nodes could theoretically land on
   different commits if someone pushes mid-deploy. S3 artifacts would pin an
   exact build.

3. **Is per-node `migrate` leadership on the gatekeeper right**, or should
   migrations be a separate deliberate step that a human runs before triggering
   the code rollout? Coupling them is convenient; decoupling them is safer.

4. **How much staleness is acceptable for website content?** We propose a ~30s
   poll. A push-trigger would be faster but requires CI to reach the job engine.

5. **Does the two-node staging environment need to exist at all?** Staging is
   currently a single node with no load balancer, which means the multi-node
   sync paths get their first real exercise in production. Standing up a second
   staging node temporarily to prove them is cheap insurance.

---

## 8. Current state

**Built and verified:**
- `aws/terraform/` — VPC, NLB with the two target groups, nodes, encrypted
  Aurora, Valkey, alarms. Plans clean; capacity presets `micro`/`small`/
  `medium`/`large`.
- `aws/certbot_sync.py` — canonical version; distributes the full certificate
  lineage with pair verification and an `nginx -t` gate before reload.
- `aws/config_sync.py` — §3.1, tested end-to-end against a live bucket.

**Proposed, not built:**
- `certbot_sync.py` extended to carry `conf.d` and derive the gatekeeper role
- `www_sync.py`
- sequenced deploy job + migration leadership
- deploy outcome → incident events

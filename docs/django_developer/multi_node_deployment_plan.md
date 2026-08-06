# Multi-node deployment — proposed design (v2)

**Status:** proposal, not built. Revised after external review.
**Date:** 2026-08-06
**Scope:** django-mojo-skeleton (and every project cloned from it)

---

## 0. What changed in v2, and what the review got right

The first draft was reviewed and found not implementation-ready. Every finding
was verified against the code; **all nine were correct**, and three were worse
than reported. Summary of what changed:

| v1 said | Reality | v2 |
|---|---|---|
| Timers guarantee convergence for every payload | API code had no timer path at all — job-only | §3.4 adds a release-pointer sync on a timer |
| Sequenced restarts give zero downtime | Nodes stay registered during restart; the NLB serves 502s until health checks notice | §3.5 defines an explicit drain → deploy → verify → re-register cycle |
| Certs + `conf.d` ship "as one payload" | Logically, not transactionally. Per-object S3 writes expose mixed state | §3.6 release manifests + atomic pointer switch |
| Publishing in order is enough coordination | Two overlapping pushes interleave | §3.5 fleet lease + immutable release SHA |
| Gatekeeper runs migrations | A convention, not a lock — and `post_deploy.sh` hides migration failure with `\|\| true` | §3.7 separate phase, advisory lock, fail hard |
| `config_sync.py` "built and verified" | The script was verified. **Nothing installs or enables it.** | §2.1 corrected; §8 current-state defects |
| Gatekeeper failover = one target-group edit | `certbot_sync.py` syncs **one** lineage; wmx has **nine**, plus renewal configs and an ACME account key that are never synced | §3.6 and §4 substantially rewritten |
| ACM capped at 25 certs — "a hard ceiling" | **Wrong, and we had the correct data.** The quota query run during this work returned `Adjustable: True`. | §6 corrected |
| Onboarding: vhost → certbot → DNS | Self-contradictory; the next paragraph said DNS must come first | §3.6 reordered, and switched to `certonly --webroot` |

The ACM error is worth calling out separately: it was not a judgement call that
went the wrong way, it was a factual claim contradicted by a command run earlier
in the same work. The rejection of ACM may still be correct, but §6 now argues
it on the actual tradeoff rather than on an invented limit.

---

## 1. What problem this solves

Today a django-mojo project runs on **one EC2 box**. Deploying means SSH in,
`git pull`, restart.

We are moving to **2–6 identical nodes behind a network load balancer**. Four
separate things then need to reach every node:

| # | Payload | Example of it changing |
|---|---|---|
| 1 | **Application config** (`var/django.conf`) | rotate an API key |
| 2 | **nginx vhosts + TLS certificates** | onboard a new tenant domain |
| 3 | **Static website builds** (`/opt/www/<project>`) | a web dev pushes to main |
| 4 | **API code** (`/opt/api`) | we ship a feature |

### 1.1 Non-negotiable constraints

These are project policy, not proposals. The design must accommodate them.

**C1. django-mojo is upgraded on every deploy, and is never pinned.**
Pinning has failed this team before: a version frozen in `requirements.txt` went
stale and critical security releases were not picked up because nobody bumped
it. `pip install --upgrade django-mojo` on every deploy is deliberate.

**C2. Migrations run on every deploy.**
Not conditionally, not manually. A deploy that skips migrations is a deploy that
leaves the schema behind the code.

Both constraints are currently *approximated* rather than met — see §8.

### 1.2 C1 conflicts with immutable release artifacts — and the fix

§3.1 says a release is an immutable id, so every node in a rollout runs
identical code. C1 says each node upgrades django-mojo to whatever is newest.
Those cannot both be true if each node resolves "newest" at its own moment:

```
10:00  node 1 deploys, resolves django-mojo 1.2.62
10:02  django-mojo 1.2.63 is published
10:05  node 2 deploys, resolves django-mojo 1.2.63
       -> fleet split across two framework versions
```

Worse, if 1.2.63 ships a migration, node 2's deploy applies it and node 1 is now
running older framework code against a newer schema — the expand/contract hazard,
in code we do not control.

**The goal and the mechanism are separable.** The goal is "never miss a security
release." The mechanism does not have to be "each node independently resolves
latest at its own moment."

**Resolve once per rollout, pin within it.** At the start of a rollout, resolve
the newest django-mojo **once**, record the exact version in the release
manifest, and have every node install *that* version. Every deploy still picks up
the newest framework — nothing is frozen across time — but all nodes in one
rollout provably agree.

This is not the pinning that caused the original problem. That was a version
sitting in `requirements.txt` for months. This is a version resolved fresh on
every single deploy and held constant only for the minutes a rollout takes.

**Consequence of C1 + C2 together:** a framework release that ships migrations
gets those migrations applied automatically, sight unseen. That is the accepted
cost of not pinning, and it raises the value of two things already in this plan:
staging running the identical rollout first (§7, settled), and the rollout
halting on migration failure instead of continuing (§3.7).

### The topology

Already built in `aws/terraform/`:

```
tenant DNS ──A──▶ NLB static IPs
                   │
                   ├── :443 TCP ──▶ every node        (player + API traffic)
                   └── :80  TCP ──▶ ONE node only     (Let's Encrypt challenges)
                                     "the gatekeeper"

each node: nginx (terminates TLS) ──▶ uvicorn ──▶ Aurora + Valkey
```

The load balancer passes TCP through without decrypting, so **each node holds
its own copy of every TLS certificate**. Port 80 reaches one node so HTTP-01
challenges always land where certbot runs.

---

## 2. The core principle

> **Timers guarantee that nodes converge. Jobs only make it faster.**

Every payload lands via a small script on a **systemd timer** that pulls and
installs if changed. That is what guarantees correctness. django-mojo's job
engine can *additionally* fire a message telling a node to run that sync now, so
a deploy takes seconds rather than a poll interval — but the job carries no
payload and does no work. It only says "check now."

**Why the job engine must never be responsible for deployment:**

1. It is part of the thing being deployed. Ship broken code through it and you
   have broken the mechanism that ships the fix.
2. A node whose app is down cannot receive a job — precisely the node that most
   needs to converge.
3. A newly booted node has no code yet, so it cannot run an engine to fetch
   code.

### 2.1 This principle is currently violated in two places

Stated as a correction, because v1 claimed otherwise:

- **API code has no timer path.** Proposed as job-only. Fixed in §3.4.
- **`config_sync.py` has no installer.** `ec2_deploy.sh:83` and
  `post_deploy.sh:35` copy `*.service` only — `config-sync.timer` is never
  copied, and neither unit is ever enabled. The script is verified; its
  *installation* is not built. Fixed in §8.

---

## 3. Proposed design

Unifying idea: **each payload has exactly one writer**, and every payload is
identified by an **immutable release id** so a node can answer "am I on the
intended release?" rather than "did I receive the message?"

| Payload | Owner | Direction | Mechanism |
|---|---|---|---|
| `django.conf` | an operator | S3 → every node | `config_sync.py` (script done, installer missing) |
| nginx `conf.d` + certs | the gatekeeper | gatekeeper → S3 → other nodes | `certbot_sync.py` — needs multi-lineage rewrite |
| `/opt/www/<project>` | CI | CI → S3 → every node | `www_sync.py` (new) |
| API code | a release artifact | S3 → every node | `api_sync.py` (new) + rollout controller |

### 3.1 The release-artifact model

Everything except config uses the same shape, so there is one idea to learn:

```
s3://<bucket>/<payload>/<project>/<env>/
    releases/
        <release-id>/          immutable; never rewritten
            manifest.json      { files: {path: sha256}, release_id, created }
            ...content...
    current                    a tiny object holding one release-id
```

**Publish** writes the release directory first, then overwrites `current` last.
**Consume** reads `current`, and if it differs from the installed release id,
stages the whole release to a scratch directory, verifies every file against the
manifest, and only then swaps it in.

This is what makes "ships as one payload" true rather than aspirational. A
consumer never sees a half-written release, because `current` does not point at
one until it is complete.

**On disk**, the same discipline:

```
/opt/www/<project>/
    releases/<release-id>/     staged, verified
    current -> releases/<id>   atomic symlink swap (rename(2))
```

Keep the last few releases so rollback is repointing a symlink.

### 3.2 Application config

`config_sync.py` (built) pulls `django.conf` from S3 on a timer and at boot.
Safety property already implemented: **if the fetch fails, keep the existing
file** — a node with stale config serves; a node with no config does not start.

Config is small and single-file, so it uses a published `sha256` rather than the
full release-directory machinery. **Outstanding:** install and enable the units
(§8), and decide whether a config change should trigger a restart via the §3.5
rollout rather than the current hostname-jitter (it should — jitter spreads
restarts but does not guarantee non-overlap).

### 3.3 Website builds

CI syncs the build to a release directory and updates `current`. Each node polls
(~30s), stages, verifies against the manifest, and swaps the symlink.

Inverting the direction — nodes pull, CI does not push — is what makes this work
at N nodes: CI needs no node inventory, a node that was down catches up, and a
**new node populates itself at boot**, which is what makes AMI-based scaling
real.

### 3.4 API code

**Corrected from v1.** Two independent paths, and the timer is the one that
guarantees convergence:

- **`api_sync.py` on a timer + at boot.** Reads the published release id,
  compares to what is installed, and if it differs, requests a rollout slot
  (§3.5). A node that missed a message, booted from an old AMI, or had its job
  engine stopped converges on its own.
- **A box-direct job** (`<hostname>-engine`, already supported —
  `mojo/apps/jobs/__init__.py:101`) that starts `api_sync` immediately.

**Deploy an immutable id, never a branch.** `git pull origin/main` means two
nodes in the same rollout can land on different commits if someone pushes
mid-deploy. Either publish an S3 artifact built once in CI (preferred — it also
removes a GitHub dependency from every node's boot path), or at minimum pin and
deploy an exact SHA. Deploying `origin/main` should be prohibited.

**A release id covers dependencies, not just application code.** Per §1.2 the
manifest carries the django-mojo version resolved once at rollout start, so
"same release id" means the same framework too. Without that, C1 silently
reintroduces the split-fleet problem this paragraph is about — just one layer
down, where it is harder to see.

### 3.5 The rollout — how zero downtime is actually achieved

**Corrected from v1**, which wrongly assumed sequencing was sufficient.
Restarting `mojo-asgi` while the node is still registered means the NLB keeps
sending traffic until health checks notice — with a 10s interval and a threshold
of 2, that is ~20s of 502s per node.

A **rollout controller** holds a fleet-wide lease and walks nodes one at a time:

```
acquire fleet lease (Redis, TTL'd)        -- refuse to start if another rollout holds it
run the migration phase (§3.7)            -- once, before any node takes new code
for each node, one at a time:
    deregister from the :443 target group
    wait for connection draining to complete
    install the release (staged, verified, symlink swap)
    restart mojo-asgi
    smoke test LOCALLY (GET /api/version on 127.0.0.1)   -- fail fast, before re-exposing
    re-register
    wait until the target reports healthy
    on failure: stop the rollout, leave remaining nodes on the old release
release lease
```

Two things this buys beyond ordering: **at most one node is ever out**, and a
failed node **halts** the rollout instead of the sequencer marching on. The lease
is what prevents two pushes seconds apart from starting two interleaved
rollouts.

Deregistration requires an AWS API call, so the rollout controller needs
credentials the sync scripts do not.

### 3.6 nginx vhosts and certificates — bigger than v1 assumed

**This is the section the review changed most.**

`certbot_sync.py` handles a **single** lineage named by `LOAD_BALANCER_DOMAIN`
(`certbot_sync.py:482`). The wmx box currently has **nine** lineages. It also
never syncs `/etc/letsencrypt/renewal/*.conf` (nine files) or the ACME account
key under `/etc/letsencrypt/accounts/`.

So v1's claim — that the gatekeeper publishes tenant certificates and replicas
pull them — **is not something the current script can do.** For a multi-tenant
platform this is the largest single gap in the plan.

What is actually needed:

- Sync **every** lineage under `/etc/letsencrypt/live/`, not one named domain.
- Sync **renewal configs**, or a replacement gatekeeper cannot renew anything.
- Decide on the **ACME account key** (below).
- Carry `conf.d` in the same release, so a vhost and the certificate it
  references land together and get one `nginx -t` and one reload. Ship them
  separately and a vhost arrives referencing a certificate the node does not
  have; `nginx -t` fails and the node stalls on old config until the next tick.

**The ACME account key is a real decision.** Replicating it lets any node take
over renewal immediately; it also means every node holds a credential that can
revoke certificates. Not replicating it means a replacement gatekeeper must
re-register and reissue — fine for nine domains, but at tenant scale that runs
into Let's Encrypt rate limits (50 certificates per registered domain per week,
300 new orders per 3 hours). **Recommendation: replicate it.** Replica nodes
already receive every private key, so the trust boundary is unchanged, and
reissuance-on-failover does not scale.

**Tenant onboarding, corrected order** (v1 had DNS after certbot, contradicting
its own next paragraph):

```
1. tenant points joecasino.xyz A ──▶ the NLB's static IPs
2. verify the name resolves to every NLB address
3. on the gatekeeper: certbot certonly --webroot -d joecasino.xyz
4. add the TLS vhost to conf.d and publish the release
5. all nodes pull certs + vhost together, nginx -t, reload
```

Using `certonly --webroot` rather than `--nginx` matters: it obtains the
certificate **without** writing a vhost that references files not yet present,
so `nginx -t` is never asked to validate a config pointing at a missing
certificate. It also removes certbot as a second writer to `conf.d`, which makes
the gatekeeper the sole author of that directory by construction rather than by
convention.

### 3.7 Migrations

**Corrected from v1.** Naming the gatekeeper as migration runner is a
convention, not a lock, and the current script actively hides failure:
`post_deploy.sh:21` runs `migrate --noinput 2>&1 || true`.

Per **C2**, migrations run on every deploy — there is no "migrations release"
and no opt-in flag. The current `if [[ -f var/allow_migrate ]]` gate
(`post_deploy.sh:19`) does not meet that constraint and should be removed; see
§8.

- Make migration a **distinct rollout phase** that completes before any node
  takes the new release.
- Serialize with a **PostgreSQL advisory lock**, not a role convention or a flag
  file, so concurrent invocations cannot both proceed. A lock is what
  `allow_migrate` was reaching for; a file cannot serialize anything.
- **Fail the rollout** on a non-zero exit. Never `|| true`.
- Migrate with the **release's resolved django-mojo version installed** (§1.2),
  so framework migrations and framework code enter the fleet together.
Migration authority should **not** be coupled to the ACME gatekeeper role. They
are unrelated concerns that happen to both want "one designated node," and
coupling them means a gatekeeper change silently moves migration authority.

### 3.7.1 Rolling vs stop-the-world is a per-release choice, not a per-system one

The framing so far — "either roll and accept a window where old code meets a new
schema, or drop everything and restart together" — is a real dilemma, but it is
only a dilemma for a **minority of releases**. Most deploys carry no migration
at all, or an additive one that old code is entirely indifferent to.

So do not pick one strategy for the system. **Classify the release, then pick.**

**Two hazards, and they are independent.** Conflating them is why this feels
harder than it is:

| Hazard | Question | Example | Mitigation |
|---|---|---|---|
| **Compatibility** | does *old code* break against the new schema? | `DROP COLUMN`, `RENAME`, type change | stop-the-world, or expand/contract |
| **Lock** | does the migration *itself* block traffic while running? | non-concurrent `CREATE INDEX`, table rewrite | write the migration differently |

They need different answers. `DROP COLUMN` in Postgres is fast — it is metadata
only — so it has no lock hazard at all, but it breaks any running old code that
still selects the column. Conversely `CREATE INDEX` without `CONCURRENTLY` is
perfectly compatible with old code, but takes an `ACCESS EXCLUSIVE` lock for the
duration, which on a large table is minutes of total outage. **Stop-the-world
does not help the second case** — the lock outlasts the restart. Only writing
the migration correctly does.

**Release classes:**

- **Class A — no migrations.** Roll. Zero risk, zero downtime. This is most
  deploys.
- **Class B — additive only.** `CREATE TABLE`, `ADD COLUMN` nullable or with a
  default, `CREATE INDEX CONCURRENTLY`, `ADD CONSTRAINT ... NOT VALID`. Roll.
  Old code simply does not see the new objects.
- **Class C — compatibility-breaking.** `DROP`, `RENAME`, type changes,
  `SET NOT NULL`. Requires a choice: stop-the-world (all nodes restart together,
  ~10–30s of downtime) or split across two releases expand/contract style.
  Should be **rare and deliberate**.

The point is that only Class C forces the dilemma, and Class C is the exception.
Requiring expand/contract for *every* migration — as v2 implied — is a
discipline burden out of proportion to the actual risk.

**This can be determined, not guessed.** `manage.py migrate --plan` says whether
there are unapplied migrations at all (Class A). `manage.py sqlmigrate` emits the
SQL for the rest, and it can be pattern-matched for the Class C operations. The
rollout controller can classify the release and either proceed rolling or refuse
to roll and demand an explicit stop-the-world flag. That converts today's "we
hope the migration doesn't impact legacy" into a decision made from evidence.

Two Postgres notes, since we are on Aurora PostgreSQL 17 and much of the folklore
here predates it: `ADD COLUMN` with a non-volatile default has been metadata-only
since PG 11, and `SET NOT NULL` can skip its table scan since PG 12 when a valid
`CHECK` constraint already proves it. Several operations that used to be Class C
are now cheap — worth verifying per case rather than assuming either way.

### 3.7.2 Prior art: payomi's `post_update.sh`

An existing production system in this family solves the same problem, and it is
worth recording both what it gets right and where it does not generalise.

What it does: upgrades the framework unpinned (`pip install django-restit
--upgrade`, the same C1 policy), then uses a wall-clock barrier —
`wait_until_seconds 50` before `migrate`, `wait_until_seconds 55` after — so
that nodes deploying in the same minute converge on a common instant.

It is a clever way to get approximate synchronisation with no coordination
primitive available. But it should not be carried forward as-is:

- **The barrier is unreliable by construction.** `wait_until_seconds 50` returns
  immediately if it is already past :50. A node arriving at :48 waits two
  seconds; a node arriving at :52 does not wait at all. Nodes starting in
  different minutes are not synchronised whatsoever.
- **It parallelises migrations rather than serialising them.** Every node
  reaching the barrier runs `migrate` at the same instant, which is the opposite
  of what is wanted. Django's `migrate` is not concurrency-safe; simultaneous
  runs race between reading `django_migrations` and applying DDL. This is very
  likely why the wmx variant grew `|| true` — to swallow the resulting duplicate
  -object errors.
- It confirms C1 is a house pattern rather than a wmx quirk, which is useful.

The advisory lock in §3.7 is the primitive the barrier was approximating. It
gives real serialisation instead of approximate simultaneity, and it does not
depend on where in the minute a node happens to arrive.

---

## 3.8 dnsman may delete most of §3.6 — investigate before building it

`certbot_sync.py`'s own docstring names dnsman's Certificate model as its
endgame. On inspection that is not aspirational — **dnsman is built**, and it
attacks the certificate problem from an angle that removes the gatekeeper rather
than improving it.

What exists in `mojo/apps/dnsman/`:

- `services/certs.py` — full ACME issuance, renewal and revocation, and its
  opening line is decisive: *"DNS-01 is the only challenge type dnsman uses,
  because it needs nothing but an [API credential]... That is what lets issuance
  and renewal run centrally on a worker."*
- `models/certificate.py` — `Certificate(KSMSecrets, MojoModel)` holding
  `cert_pem`, `chain_pem`, and the private key in **KMS-backed secrets**, with
  `not_after` / `renew_after` for scheduling.
- `models/acme_account.py` — one account per directory URL, key in KMS, no REST
  surface.
- `asyncjobs.certificate_updated` — broadcast to **every runner** on
  `DNSMAN_CERT_SYNC_CHANNEL` when a certificate changes, carrying identifiers
  only; consumers pull the material through a gated endpoint with their own
  credentials.
- Wildcard support (`normalize_names` defaults to apex plus wildcard), and
  Route53 + GoDaddy providers.

**What this deletes, if adopted.** DNS-01 needs no port 80 at all, so:

| §3.6 work item | Under dnsman |
|---|---|
| port-80 `certbot-targets` group + gatekeeper role for certs | **gone** — no HTTP-01 challenge to route |
| multi-lineage S3 sync (nine lineages) | **gone** — DB is the single source |
| renewal-config replication | **gone** |
| ACME account key replication, and its revocation-credential tradeoff | **gone** — one account, in KMS, never on a node |
| S3 release manifest atomicity for certs | **gone** — a row is atomic |
| tenant offboarding (unhandled today) | delete the row |
| `PRIMARY_BALANCER_HOST` | **gone** |

That is the majority of the most complex section of this plan, removed rather
than built.

**What dnsman does not provide:** the node-side installer. The docstring is
explicit — *"dnsman itself has nothing to install, so the framework handler only
logs."* Something must still write PEMs to disk, `nginx -t`, and reload. That is
`certbot_sync.py`'s job, but a much smaller version of it: pull one cert from a
REST endpoint, install, reload. No S3, no direction, no primary/replica, no
account key.

### The blocking constraint, stated plainly

**DNS-01 requires API control of the zone**, and dnsman has **no CNAME-delegation
support** — verified: nothing in `services/certs.py` or `models/domain.py`
handles a delegated `_acme-challenge`. So today it can only issue for zones we
hold Route53 or GoDaddy credentials for.

That is a real problem for exactly our use case:

- **Our own domains** — works, *if* we have API access to the zone. It has been
  stated that GoDaddy API access is not held for every project, including this
  one. That is the first thing to check.
- **Tenant BYO domains (joecasino.xyz)** — does **not** work. The tenant controls
  their DNS; we cannot write their `_acme-challenge` TXT.

**Proposed phasing rather than a single decision:**

1. **Now — adopt dnsman for our own domains with a wildcard.** A single
   `*.wmwx.io` + `wmwx.io` certificate replaces eight of the current nine
   lineages. The multi-lineage sync problem shrinks from nine moving parts to
   one wildcard plus N tenant domains, which is a large reduction in §3.6 before
   writing any of it. Requires DNS API access to the `wmwx.io` zone.
2. **Next — add CNAME delegation to dnsman.** The tenant adds one permanent
   `_acme-challenge.joecasino.xyz CNAME <something>.acme.wmwx.io`; we own the
   target zone and answer every future challenge without touching their DNS
   again. This is a contained feature and it is what makes dnsman viable for a
   multi-tenant platform.
3. **Then — retire certbot, the port-80 target group, and the gatekeeper role**
   for certificates entirely.

**Intellectual honesty about ACM.** Step 2 asks tenants for a permanent CNAME —
which is the same operational burden §6 rejects ACM over. If we are willing to
ask for that record, ACM becomes more competitive than §6 admits. dnsman still
wins on two counts that ACM cannot match: TLS stays terminated on the node so we
keep TCP passthrough, and there is no per-balancer certificate quota to keep
renegotiating. But the CNAME burden should stop being an argument against ACM if
we adopt it ourselves.

**Recommendation: do not build the §3.6 multi-lineage S3 sync until step 1 is
evaluated.** It is the largest work item in this plan and dnsman may remove most
of its justification. The wildcard alone changes the shape of the problem.

## 3.9 Bootstrapping the first certificate — there is no chicken-and-egg

The obvious worry: dnsman is driven from the admin portal, the portal needs
HTTPS, HTTPS needs a certificate, and the certificate comes from dnsman.

**That circle does not exist, and the reason is the whole point of DNS-01.**

HTTP-01 requires Let's Encrypt to reach *your server* on port 80 — which is why
it forces the port-80 gatekeeper, and why it would create a genuine bootstrap
paradox. DNS-01 requires nothing to reach your server at all. The ACME server
queries **public DNS**; your box only makes outbound calls, to Let's Encrypt and
to the DNS provider API.

So the first certificate can be issued on a box that has no valid certificate,
has nginx stopped, has 80 and 443 closed, and is not publicly reachable. It
needs only:

- Django and a migrated database (dnsman's tables)
- one `DnsCredential` row for the zone — the single manual secret
- outbound HTTPS

That makes bootstrap a **local management command**, not a portal workflow. No
HTTPS required to obtain HTTPS.

### `manage.py dnsman_bootstrap` — proposed

dnsman currently ships **no management commands** (verified), so this is new.
It should be idempotent, synchronous, and safe to re-run.

```
manage.py dnsman_bootstrap --domain wmwx.io --wildcard --install
```

1. Check the DB is reachable and dnsman's migrations are applied.
2. Ensure a verified `DnsCredential` for the zone; prompt or take arguments if
   absent. This is the one thing a human must supply.
3. Ensure the `Domain` row exists.
4. `certs.request_certificate(domain, ["wmwx.io", "*.wmwx.io"])`.
5. **Issue synchronously.** `request_certificate` only queues
   `publish_job(ISSUE_JOB, cert)`, so issuance normally happens on a job runner.
   Bootstrap cannot assume a runner is up, so the command must call
   `certs.issue(cert)` directly and wait.
6. Write `cert_pem` / `chain_pem` / private key to the path nginx expects, key
   at `0600`.
7. `nginx -t`, and reload only if it passes.

Re-running with a valid certificate already present should skip to step 6 and
just re-install to disk — which doubles as the recovery path for a node whose
local copy was lost.

### 3.9.1 With CNAME delegation — and why it solves more than tenants

Delegation is in flight and not yet merged (verified: no delegation references in
`mojo/apps/dnsman/` as of this writing), so this is a spec, not a description.

**The realization worth leading with: delegation is not only for tenant domains.
It removes the "do we have DNS API access for this zone?" problem entirely.**

§3.8 named that as the blocker for step 1 — GoDaddy API access is not held for
every project, including this one. Delegation dissolves it:

```
one zone we fully control via API, e.g. acme.mojoverify.com  (Route53)

_acme-challenge.wmwx.io       CNAME  wmx-io.acme.mojoverify.com      <- ours
_acme-challenge.clubaxo.com   CNAME  clubaxo-com.acme.mojoverify.com <- ours
_acme-challenge.joecasino.xyz CNAME  joecasino-xyz.acme.mojoverify.com <- tenant's

dnsman writes the TXT into acme.mojoverify.com; ACME follows the CNAME.
```

We then need API credentials for **exactly one zone, ever**. Every other
domain — ours or a tenant's — joins with a single manual CNAME added once at
whatever registrar happens to hold it. No API access to `wmwx.io` required.

**So use delegation uniformly, including for our own domains.** One credential,
one code path, one onboarding procedure. The alternative — direct DNS-01 where
we have API access, delegated where we don't — means two paths and a per-domain
decision about which applies.

### The bootstrap sequence, with delegation

```
ONCE per organisation:
  1. create the delegation zone in Route53
  2. scope a credential to that hosted zone only

ONCE per domain (including the very first one):
  3. add _acme-challenge.<domain> CNAME <label>.acme.<zone> at the registrar
     -- manual, no API, and it never changes again
  4. VERIFY the CNAME resolves before attempting issuance   <-- see below
  5. manage.py dnsman_bootstrap --domain <domain> --wildcard --install
```

Nothing here needs HTTPS, the portal, or inbound connectivity, so §3.9's
conclusion holds unchanged.

### The trap: verify the CNAME before issuing

**Let's Encrypt rate-limits failed validations — 5 per account per hostname per
hour.** Firing issuance before the delegation CNAME has propagated burns those
attempts and locks you out for an hour, during a bootstrap, which is precisely
when you are iterating and least able to wait.

`dnsman_bootstrap` must therefore **pre-flight**: resolve
`_acme-challenge.<domain>`, confirm it is a CNAME pointing at the expected
target, and refuse to proceed otherwise. A local DNS lookup is free; a burnt
rate limit costs an hour. This is the single most valuable thing the command
does beyond wrapping the existing service calls.

Note there are **two** propagation waits, not one, and they have very different
characters:

| Wait | Owner | Typical |
|---|---|---|
| delegation CNAME | a human, at the registrar | minutes to hours, depends on the zone's TTL |
| challenge TXT | dnsman, in our own zone | seconds — we control the TTL |

Only the second is dnsman's to manage. The first is why step 4 exists.

### What delegation must get right

Two requirements that fall out of how ACME works, worth stating before the
implementation lands:

- **Multiple TXT values on one name.** A wildcard and its apex produce two
  separate authorizations that share the record name `_acme-challenge.<domain>`
  and require *both* digests present simultaneously — `certs.py` already notes
  this. Under delegation both land at the same delegated label, so the writer
  must add TXT values rather than replace them, or the wildcard and apex will
  clobber each other.
- **Unique labels per domain.** Many domains delegating into one zone need
  distinct targets or they collide. `Domain` needs a stored delegation label,
  generated once and stable, since the tenant's CNAME points at it forever.

### The delegation zone is a high-value target

Worth naming explicitly: **whoever can write to the delegation zone can obtain a
certificate for every domain delegated to it** — including tenants'. That is a
meaningful concentration of authority that does not exist in the current
per-box certbot setup.

Mitigations, none expensive: make it a **dedicated** zone rather than a
subdomain of an operational one; scope the credential to that single hosted zone
(Route53 IAM supports this); and keep it out of `django.conf` once nodes carry an
instance profile. The credential's blast radius should be "can write TXT records
in one zone," not "can manage our DNS."

### The one real ordering constraint

nginx will not start with `ssl_certificate` pointing at a file that does not
exist. A brand-new node therefore cannot serve 443 before its first certificate,
which would leave no way to observe the box while bootstrapping.

**Ship a self-signed placeholder in the AMI** at the same paths. The box then
comes up serving 443 with a browser warning rather than not serving at all, one
nginx config works in both states, and the bootstrap simply replaces the files
and reloads. Cheaper than maintaining two nginx configurations.

### Bringing up a new environment, end to end

```
terraform apply
   -> nodes boot, self-signed placeholder serves 443
   -> config_sync pulls django.conf
   -> migrate                              (dnsman tables exist)
   -> seed the DnsCredential               (the one manual secret)
   -> manage.py dnsman_bootstrap --domain <apex> --wildcard --install
        DNS-01: no inbound connectivity needed
   -> real certificate on disk, nginx reloaded
   -> admin portal reachable over HTTPS
   -> every subsequent domain is done through the portal
```

This is exactly the "hand an AI session a script and let it stand up an
environment" shape: everything before the portal is one command with one secret.

## 4. The gatekeeper

**Still recommending against automatic failover**, for reasons v1 gave and the
review did not dispute: the target group is the real gatekeeper, so an election
that does not move it changes nothing; and certificate expiry gives weeks, not
seconds. The right control is an **alarm at 21 days to expiry**, which catches
every underlying cause at once.

**But v1 understated the work.** "One target-group edit" is only true once
§3.6 is done — every lineage plus renewal state must already be on the
replacement node, or it can serve existing certificates and renew none of them.
Until then, gatekeeper replacement is a documented, rehearsed procedure, not a
one-liner.

**On deriving the role:** v1 proposed asking the ELB API "am I in the certbot
target group?" The review's counter is better and is adopted — **have Terraform
write both the target-group membership and a local role marker from the same
input**. One source of truth, no drift, and no minute-level safety decision
depending on an AWS API being reachable. `PRIMARY_BALANCER_HOST` in
`django.conf` goes away; the marker file replaces it.

---

## 5. What belongs in django-mojo

- **Rollout controller** — the lease, the per-node state machine, target
  deregistration. This is the substantial piece.
- **Trigger** — box-direct deploy jobs.
- **Observability** — each node's deploy outcome as an incident event under
  `system:deploy:*`, so a node that silently failed to converge appears on the
  dashboard instead of being found weeks later.

**Not** in django-mojo: carrying the payload, or being required for a node to
converge.

---

## 6. Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| Job engine performs the deploy rather than triggering it | Circular dependency; cannot reach a node whose app is down; cannot bootstrap a new node. §2 |
| Shared network filesystem (EFS) for content and certs | Adds a shared mutable failure domain to an architecture whose purpose is that no single component takes down the fleet |
| **Terminate TLS at the load balancer with AWS ACM** | **Corrected.** The 25-certificate figure is the *default* quota and is adjustable — not a ceiling. The real objection is operational: every tenant must add a DNS validation record that persists forever, and silent renewal failure follows if anyone removes it. That burden, against per-tenant onboarding volume, is the actual decision — and it should be revisited if tenant count grows enough that self-managed renewal becomes the larger burden. |
| Redis-elected gatekeeper with automatic failover | Does not move the load balancer's port-80 target, so it does not change where challenges land. §4 |
| CI pushes directly to every node | Requires a node inventory that goes stale; silently skips nodes that are down; new nodes are not populated |
| Bake `django.conf` into the AMI | Makes the image a secret-bearing artifact; rotation requires a re-bake |
| Deploy `origin/main` | Two nodes in one rollout can land on different commits. §3.4 |

---

## 7. Open questions

Reduced from v1 — the review answered four of the five. Remaining:

1. **S3 artifacts or pinned Git SHA for API code?** The review prefers
   artifacts, and we agree; the open part is whether to build that pipeline now
   or ship pinned-SHA first and migrate. Artifacts remove GitHub from every
   node's boot path, which is the stronger argument.

2. **Replicate the ACME account key to all nodes?** §3.6 recommends yes on rate-
   limit grounds. The counter-argument — every node holding a revocation-capable
   credential — deserves a second opinion, though replicas already hold every
   private key.

3. **Does the rollout controller live in django-mojo or as a standalone
   script?** In django-mojo it gets the job engine, Redis, and incident
   reporting for free. Standalone, it keeps working when the app is broken —
   which is exactly when a rollout is most needed.

**Settled by review:** gatekeeper role from Terraform-generated markers (not the
ELB API); migrations as a separate locked phase; ~30s website staleness once
installation is atomic; two-node staging as a release gate.

---

## 8. Current state, including defects found

**Built and verified:**
- `aws/terraform/` — VPC, NLB with both target groups, nodes, encrypted Aurora,
  Valkey, alarms. Plans clean; capacity presets.
- `aws/certbot_sync.py` — distributes **one** lineage with pair verification and
  an `nginx -t` gate. Correct for what it does; insufficient for §3.6.
- `aws/config_sync.py` — script verified end-to-end against a live bucket.

**Defects in the existing deploy path, all verified:**

1. **`post_deploy.sh` swallows nine failures with `|| true`** — including
   `pip install --upgrade django-mojo` (line 14), `pip install -r
   requirements.txt` (line 17) and `migrate` (line 21). A failed dependency
   install or migration is invisible and the app restarts anyway, against the
   wrong schema or with missing packages. This is the most immediately dangerous
   item in this document.

   Note what line 14 means against **C1**: the policy is "never miss a security
   release," and the command implementing it discards its own exit status. A
   node that cannot reach PyPI, or hits a resolver conflict, silently keeps the
   old django-mojo and reports a successful deploy. The constraint is stated but
   not currently enforced.

1b. **Migrations do not run on every deploy** (**C2**). `post_deploy.sh:19`
   gates `migrate` behind the existence of `var/allow_migrate`. The file happens
   to exist on the current box, so migrations do run there — but it is opt-in
   per box, which means a node built from an AMI without it silently skips
   migrations forever, and two boxes that both have it both migrate
   concurrently. Replace the flag with the advisory lock in §3.7.
2. **`config-sync.timer` is never installed** — `ec2_deploy.sh:83` and
   `post_deploy.sh:35` copy `*.service` only, and neither unit is enabled.
3. **`certbot_sync.py` covers one of nine lineages**, and no renewal configs or
   account key. §3.6.
4. **`post_deploy.sh:39` restarts `mojo-asgi` while the node is registered.**
   §3.5.

**Proposed, not built:** `api_sync.py`, `www_sync.py`, the rollout controller,
multi-lineage `certbot_sync`, Terraform role markers, deploy events → incidents.

Item 1 is worth fixing independently of everything else here — it applies to the
single-node deployment running today.

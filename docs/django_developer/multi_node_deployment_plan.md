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
- Keep the **expand/contract discipline**: add nullable columns and new tables in
  the release *before* the code that uses them; drop them in the release *after*
  the code that stopped using them. A rolling deploy guarantees a window where
  old code meets the new schema — this constrains how migrations are *written*,
  not just how they are run, so it belongs in the project's model conventions.

Migration authority should **not** be coupled to the ACME gatekeeper role. They
are unrelated concerns that happen to both want "one designated node," and
coupling them means a gatekeeper change silently moves migration authority.

---

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

# Updating Code

Once a node is provisioned (see [Provisioning](provisioning.md)), code reaches
the fleet through the **django-mojo edge deploy plane**: a push to `main`
fires the GitHub webhook, one node orchestrates, a **canary node** takes the
release first — pinned commit, pinned framework version, migrations under a
real Postgres advisory lock — and only a proven release is rolled to the rest
of the fleet. Full design: django-mojo `docs/django_developer/edge/deploy.md`.

## The three ways an update happens

| Trigger | What it does |
|---|---|
| **Push to `main`** | GitHub webhook → `/api/github/deploy/webhook` → canary deploy of exactly the pushed commit. The normal path; nothing else to run. |
| **`POST /api/edge/deploy`** `{"sha": "<commit>"}` (global `manage_deploy`) | Manual fleet deploy of a named commit — same canary flow. |
| **`bash aws/update.sh --manual`** on one box, via SSH | Hands-on single-node update to `origin/main` + latest framework. No canary, no status reports — for fixing one node, never for deploying. |

A **bare** `bash aws/update.sh` is a usage error on purpose: the deploy argv
(`--sha`/`--framework`) is the orchestrator's contract, and a muscle-memory
bare run mid-deploy must not race the fleet.

## What `aws/update.sh` does (deploy mode)

```
flock var/update.lock              # one run per box; deploys queue, --manual fails fast
short-circuit if already on --sha + --framework
record var/previous_sha + var/previous_framework
git fetch && git reset --hard <sha> && git clean -fd
sudo bash aws/post_deploy.sh --framework <version> [--migrate]
  # pip install django-mojo==<version>, deps, [migrate_locked --noinput],
  # collectstatic, nginx configs + test + reload, systemd units, restart, probe
[--migrate only] manage.py sanity_check
[--migrate only] manage.py deploy_status set deploying --sha <sha>
bin/jobman stop                    # LAST — cron's `jobman start` revives it in ≤1min
```

On a `--migrate` (canary) failure it reports
`deploy_status set failed --sha <sha>` **first**, *then* rolls back to the
recorded previous commit + framework and re-runs `sanity_check` — the report
comes first because the rollback may reinstall a framework version that
predates the `deploy_status` command. Fleet nodes (no `--migrate`) never
write status: a failure exits non-zero while the `deploy_node` job is still
alive, and that job files the incident.

## Migrations

**Locked, exactly once per deploy, and only when the deploy says so.**
`post_deploy.sh --migrate` runs `manage.py migrate_locked --noinput`, which
holds a Postgres advisory lock in the same session as `migrate` — a
concurrent invocation (another box, a hand-run) exits non-zero instead of
racing. The old `var/allow_migrate` flag file is gone: a per-box flag cannot
serialise anything. To run a migration by hand outside a deploy:
`python3 bin/manage.py migrate_locked --noinput`.

## Observing a deploy

The durable record is the incident stream (`category "edge_deploy"` — canary
failures, timeouts, nodes that failed to converge). Point-in-time state:
`python3 bin/manage.py deploy_status get` on any node.

## Cutover from the legacy broadcast flow (one-time, per fleet)

The old flow (`.github/workflows/deploy.yml` → `POST /api/system/update` →
every node resets to `origin/main` at once) is removed from this tree. To
move a **running** fleet that still serves the old endpoint:

1. **Publish the django-mojo release** carrying the edge deploy plane
   (≥ 1.5.0). The cutover's own `pip install --upgrade` is what installs it.
2. Put `GITHUB_WEBHOOK_SECRET` into the S3-published `var/django.conf`
   (`aws/deploy.py` writes it in the cache step) and create the push webhook
   (`python aws/deploy.py --step github-webhook`). Until cutover it collects
   harmless 404s.
3. Merge the new tree to `main`. No workflow fires — it was deleted with the
   merge.
4. **One final legacy trigger**: `curl -X POST https://<domain>/api/system/update
   -H "Authorization: apikey <old SYSTEM_UPDATE_TOKEN>"` — the running nodes
   still serve the old endpoint, so every node takes one last legacy-style
   update that lands the new scripts, the new framework, and removes the old
   plane from the deployed tree.
5. **Apply the new apps' migrations once** (edge + github tables): on any one
   node, `python3 bin/manage.py migrate_locked --noinput`.
6. **Re-bake the golden AMI** (`python aws/deploy.py --step bake-ami`): a
   node booted from the old AMI has no `EDGE_DEPLOY_SCRIPT` in its baked
   settings and would refuse deploys — under the new flow the AMI must start
   current.

A node that was down during step 4 keeps serving old code and takes no
deploys (it shows up missing from the orchestrator's runner snapshot); bring
it over with `--manual` or replace it from the re-baked AMI. Fresh
provisioning needs no cutover — a new clone never had the old plane.

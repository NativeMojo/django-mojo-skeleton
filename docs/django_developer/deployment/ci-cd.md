# CI/CD

**CI does not deploy, and there is no deploy workflow.** A push to `main`
deploys itself: GitHub delivers the push event to
`/api/github/deploy/webhook` (HMAC-signed with `GITHUB_WEBHOOK_SECRET`), and
the fleet runs a canary deploy of exactly the pushed commit — see
[Updating Code](updating.md). The old `.github/workflows/deploy.yml`, its
`SYSTEM_UPDATE_TOKEN` repo secret and the `/api/system/update` broadcast
endpoint are gone; the webhook replaced all three.

No test step runs in CI either. That's a deliberate tradeoff, not an
oversight: this project's tests need Postgres and Valkey (see
`.claude/rules/testing.md` — tests hit a real running dev server, not mocks),
which is more CI setup than a small project wants to own. Run `bin/run_tests`
locally before merging; the deploy's own canary is the backstop — a broken
release fails on one node and rolls back instead of reaching the fleet. If
you outgrow that tradeoff, GitHub Actions service containers
(`postgres:`/`redis:` YAML service blocks) can spin up both as throwaway
sidecars for a test workflow without any real infra to manage.

## Setup

One step: create the push webhook.

```bash
python aws/deploy.py --step github-webhook
```

It creates the webhook on the repo (`gh api`) pointing at
`https://<your domain>/api/github/deploy/webhook`, content type
`application/json`, signed with the `GITHUB_WEBHOOK_SECRET` that
`aws/deploy.py` generated into `var/deploy.json` and wrote into the
S3-published `var/django.conf` (every node behind the LB verifies deliveries
with it).

### If `gh` can't do it

`gh` is frequently authenticated as an account with no access to the repo
being deployed — a plain 404, indistinguishable from "not installed" from
the script's side. When that happens the step prints the exact manual
recipe: the payload URL, content type, the secret value, and which events to
select. The SSH deploy key that lets EC2 nodes clone the repo has the same
"`gh` probably can't do this" situation — `aws/remote_deploy.sh` prints the
same kind of copy-pasteable fallback.

Every push to `main` — direct or merged — triggers a canary fleet deploy.

# CI/CD

`.github/workflows/deploy.yml` calls the [remote update trigger](updating.md#remote-trigger-recommended-for-more-than-one-node)
on every push to `main` — no test step runs in CI.

That's a deliberate tradeoff, not an oversight: this project's tests need
Postgres and Valkey (see `.claude/rules/testing.md` — tests hit a real
running dev server, not mocks), which is more CI setup than a small project
wants to own. Run `bin/run_tests` locally before merging; the workflow
trusts that gate rather than re-running it. If you outgrow that tradeoff,
GitHub Actions service containers (`postgres:`/`redis:` YAML service blocks)
can spin up both as throwaway sidecars for the job without any real infra to
manage — add a test step ahead of the deploy step at that point.

## Setup

1. Edit `.github/workflows/deploy.yml`, replacing `yourdomain.com` with your
   real domain.
2. Add a repo secret `SYSTEM_UPDATE_TOKEN` with the same value as
   `SYSTEM_UPDATE_TOKEN` in `var/deploy.json`. `aws/deploy.py`'s
   `github-secret` step (part of a normal full run, or `--step github-secret`
   on its own) tries to set this for you via `gh secret set` — no need to do
   it by hand if that succeeds.

### If `gh` can't do it

`gh` is frequently authenticated as an account with no access to the repo
being deployed — a plain 404, indistinguishable from "not installed" from
the script's side. When that happens `aws/deploy.py` prints the exact
manual steps, including the token value, so there's never a guessing game:

1. Open `https://github.com/<owner>/<repo>/settings/secrets/actions`
2. Click "New repository secret"
3. Name: `SYSTEM_UPDATE_TOKEN`, Value: (printed by the script, or read it
   straight from `var/deploy.json`)
4. Click "Add secret"

The SSH deploy key that lets EC2 nodes clone the repo has the same
"`gh` probably can't do this" situation — `aws/remote_deploy.sh` prints the
same kind of exact, copy-pasteable fallback (repo settings URL, the actual
public key, which checkbox to leave unchecked) rather than just suggesting
you troubleshoot `gh` further.

Every push to `main` — direct or merged — now triggers a fleet-wide update.

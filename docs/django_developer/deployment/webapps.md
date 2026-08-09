# WebApp deployment with GitHub Actions

This is the standard for static WebApps hosted by django-mojo's edge vhosts.
It is separate from deploying the Django backend itself.

Copy [`examples/github/workflows/deploy-webapp.yml`](../../../examples/github/workflows/deploy-webapp.yml)
to `.github/workflows/deploy-webapp.yml` in the WebApp repository. The example
is inactive in this skeleton and becomes active only after it is copied.

## Ownership model

- One WebApp has one service credential, linked by an administrator.
- GitHub holds that credential as an Actions secret named exactly
  `MOJO_DEPLOY_KEY`.
- Developers do not receive or install deploy credentials. Merging or pushing
  to the configured deployment branch is the deploy action.
- The credential can release only its linked WebApp; it cannot deploy another
  site or use the generic job API.

## One-time setup

1. From the already-running Django platform, bootstrap the WebApp's first key
   and pipe it straight into the GitHub repository. This path does not require
   web-mojo admin or an `ADMIN_ACCESS_TOKEN`:

   ```bash
   ssh api-host '/opt/api/.venv/bin/python /opt/api/manage.py webapp_bootstrap \
     --webapp 42 --token-only' \
     | gh secret set MOJO_DEPLOY_KEY --repo YOUR_ORG/YOUR_WEBAPP
   ```

   If the WebApp row does not exist yet, its vhost must already exist and its
   bucket must be allowed by the platform:

   ```bash
   ssh api-host '/opt/api/.venv/bin/python /opt/api/manage.py webapp_bootstrap \
     --group 123 --slug portal --vhost 456 --bucket edge-releases \
     --token-only' \
     | gh secret set MOJO_DEPLOY_KEY --repo YOUR_ORG/YOUR_WEBAPP
   ```

   The command writes `MOJO_WEBAPP_ID` to stderr while stdout contains only
   the token. It refuses to replace an existing credential unless `--rotate`
   is explicit.

2. Set the non-secret repository variables used by the workflow:

   ```bash
   gh variable set MOJO_API_URL --body "https://api.example.com" \
     --repo YOUR_ORG/YOUR_WEBAPP
   gh variable set MOJO_WEBAPP_ID --body "42" \
     --repo YOUR_ORG/YOUR_WEBAPP
   ```

3. Copy the example workflow, change the deployment branch, Node version,
   build command, or artifact directory when the project differs, and commit
   it. Keep the central action pinned to a released ref. `@v1` follows
   compatible v1 fixes; pin a full release tag for change-controlled projects.

4. Protect the deployment branch. Require pull-request review and the
   repository's test/build checks so merging is the deliberate deploy event.
   Do not allow untrusted fork workflows to receive repository secrets.

## What a run does

The repository builds its own application first. Only the final deploy step
receives `MOJO_DEPLOY_KEY`. That step:

1. hashes the built directory into a deterministic immutable manifest;
2. registers `github.sha` as the release version;
3. uploads each file directly through a checksum-bound presigned URL;
4. asks the platform to verify every uploaded object; and
5. waits for every active edge runner to converge.

Rerunning the same commit and identical artifact is safe. Reusing the commit
SHA for different bytes is rejected. If any active runner fails, the platform
restores the previous release and the action fails with bounded runner
diagnostics. A later deployment is never overwritten by an older rollback.

There is no separate promotion approval, manual hold, or admin deployment
button. The protected GitHub branch is the human control plane. To roll back
intentionally, rerun the workflow for the older commit; its immutable artifact
is reused and converged through the same path.

## Rotation and recovery

Rotate from web-mojo admin after it is live, or run `webapp_bootstrap --webapp
<id> --rotate --token-only` and pipe it into `gh secret set` again. Rotation is
a hard cutover: the prior credential stops working as soon as the new one is
minted. A run caught in that short interval fails safely and can be rerun.
Revoking or rotating a key does not change the release already being served.

## Monorepos and environments

Use a separate GitHub Environment for each WebApp/environment combination.
Define the same exact `MOJO_DEPLOY_KEY` secret name and `MOJO_API_URL` /
`MOJO_WEBAPP_ID` variables inside each environment, then set `environment:` on
the corresponding job. Add path filters per WebApp and keep one non-cancelling
concurrency group per WebApp ID so two releases never race.

For the platform API and complete release contract, see the
[django-mojo WebApp release documentation](https://github.com/NativeMojo/django-mojo/blob/main/docs/web_developer/edge/releases.md).

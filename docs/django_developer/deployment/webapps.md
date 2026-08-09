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

1. An administrator creates the WebApp and calls the authenticated platform
   endpoint below. The response shows the token once. Calling it again rotates
   the key and immediately deactivates the previous one.

   ```http
   POST /api/edge/webapp/link_key
   Content-Type: application/json

   {"webapp": 42}
   ```

2. Store the returned `data.token` directly in GitHub. Avoid putting it in a
   command argument or developer configuration:

   ```bash
   gh secret set MOJO_DEPLOY_KEY --repo YOUR_ORG/YOUR_WEBAPP
   # Paste the token at the hidden prompt, then press Ctrl-D.
   ```

3. Set the non-secret repository variables used by the workflow:

   ```bash
   gh variable set MOJO_API_URL --body "https://api.example.com" \
     --repo YOUR_ORG/YOUR_WEBAPP
   gh variable set MOJO_WEBAPP_ID --body "42" \
     --repo YOUR_ORG/YOUR_WEBAPP
   ```

4. Copy the example workflow, change the deployment branch, Node version,
   build command, or artifact directory when the project differs, and commit
   it. Keep the central action pinned to a released ref. `@v1` follows
   compatible v1 fixes; pin a full release tag for change-controlled projects.

5. Protect the deployment branch. Require pull-request review and the
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

## Rotation and recovery

`link_key` is a hard cutover: the prior credential stops working as soon as the
new one is minted. Capture the new token and immediately replace the GitHub
secret. A run caught in that short interval fails safely and can be rerun.
Revoking or rotating a key does not change the release already being served.

Automatic deployment is the WebApp default. Setting `auto_promote=False` is an
explicit manual hold; the action verifies the upload but then fails because it
cannot honestly call the release deployed. An administrator can promote or
roll back with `POST /api/edge/webapp/promote`, which uses the same fleet
coordinator.

## Monorepos and environments

Use a separate GitHub Environment for each WebApp/environment combination.
Define the same exact `MOJO_DEPLOY_KEY` secret name and `MOJO_API_URL` /
`MOJO_WEBAPP_ID` variables inside each environment, then set `environment:` on
the corresponding job. Add path filters per WebApp and keep one non-cancelling
concurrency group per WebApp ID so two releases never race.

For the platform API and complete release contract, see the
[django-mojo WebApp release documentation](https://github.com/NativeMojo/django-mojo/blob/main/docs/web_developer/edge/releases.md).

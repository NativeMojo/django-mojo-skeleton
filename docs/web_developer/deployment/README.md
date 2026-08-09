# WebApp deployment

Static WebApps deploy from their GitHub repository when a developer merges or
pushes to the configured deployment branch. GitHub builds the application and
uses the repository secret named exactly `MOJO_DEPLOY_KEY`; developers do not
receive deploy keys.

Start with the copy-ready
[`examples/github/workflows/deploy-webapp.yml`](../../../examples/github/workflows/deploy-webapp.yml).
The Git commit SHA is the immutable release version. The workflow succeeds only
after the active edge fleet reports the release live; a failed convergence
rolls back and fails the workflow.

GitHub is the only deployment control plane. There is no separate human
promotion step or manual hold. Rerun the workflow for an older commit to roll
back intentionally.

Administrators can follow the complete [setup and rotation runbook](../../django_developer/deployment/webapps.md).

# Deployment

- [Provisioning](provisioning.md) — **who owns the infrastructure** (the admin
  portal by default; OpenTofu under `INFRASTRUCTURE_MODE = "external"`), and
  first-time AWS stand-up via `aws/deploy.py`
- [Updating code](updating.md) — **start here**: how a push becomes a canary
  fleet deploy, the three update triggers, migrations, and the one-time
  cutover checklist from the legacy broadcast flow
- [CI/CD](ci-cd.md) — backend/API pushes deploy through the GitHub webhook
- [WebApp deployment](webapps.md) — copy-ready GitHub Actions workflow and
  `MOJO_DEPLOY_KEY` setup for static edge-vhost applications

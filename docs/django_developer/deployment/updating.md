# Updating Code

Once a node is provisioned (see [Provisioning](provisioning.md)), there are
two ways to push a code change — both run the same `aws/update.sh`.

## Remote trigger (recommended for more than one node)

```bash
curl -X POST https://yourdomain.com/api/system/update \
  -H "Authorization: apikey <SYSTEM_UPDATE_TOKEN>"
```

`SYSTEM_UPDATE_TOKEN` lives in `var/deploy.json`. The endpoint
(`apps/system/system/rest/update.py`) broadcasts a job via
`jobs.broadcast_execute` — every node running `jobman` picks it up and runs
`aws/update.sh` in the background (see `apps/system/system/asyncjobs.py`).
This is what [CI/CD](ci-cd.md) calls on every push to `main`.

## Manual (single node, hands-on)

```bash
ssh -i <your-pem> ec2-user@<node-ip>
cd /opt/api && bash aws/update.sh
```

## What `aws/update.sh` does

```
git fetch origin && git reset --hard origin/main && git clean -fd
sudo bash aws/post_deploy.sh   # pip deps, collectstatic, nginx reload, restart mojo-asgi
jobman stop                    # cron restarts it within a minute
```

**Migrations are opt-in per update.** `post_deploy.sh` only runs
`manage.py migrate` if `var/allow_migrate` exists on the node — this keeps a
routine push from silently running a migration unattended. If your change
includes a migration, either `touch var/allow_migrate` on the node once, or
run `python3 bin/manage.py migrate --noinput` by hand after the update.

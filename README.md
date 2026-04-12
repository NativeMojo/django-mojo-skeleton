# django-mojo-skeleton

Project skeleton for building applications with [django-mojo](https://github.com/NativeMojo/django-mojo).

## Quick Start

### 1. Clone and rename

```bash
cp -r django-mojo-skeleton ~/Projects/mojo/my-new-project
cd ~/Projects/mojo/my-new-project
```

### 2. Update project references

- `pyproject.toml` — name, description, dependencies
- `config/settings/version.py` — version
- `config/settings/local/db.py` — database name, cache prefix
- `bin/setup_local_postgres` — `MOJO_PG_DB` default
- `aws/nginx/conf.d/app.conf` — domain name
- `CLAUDE.md` — project description

### 3. Create your app

```bash
mkdir -p apps/my_app/myapp/{models,rest,services,management/commands}
touch apps/my_app/myapp/__init__.py
touch apps/my_app/myapp/models/__init__.py
touch apps/my_app/myapp/rest/__init__.py
touch apps/my_app/myapp/services/__init__.py
```

Add your app to `apps/apps.json`:
```json
{
    "installed": [
        ...
        "myapp",
        ...
    ]
}
```

### 4. Set up local development

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
./bin/setup_local_postgres --migrate
.venv/bin/python ./bin/manage.py runserver 9009
```

### 5. Deploy to AWS

```bash
# Provision infrastructure
python aws/deploy.py

# On EC2 (after bootstrap runs via user_data):
git clone git@github.com:YourOrg/my-new-project.git /opt/api
sudo bash /opt/api/aws/ec2_deploy.sh
echo "prod" > /opt/api/var/profile
# Edit /opt/api/var/django.conf with credentials
/opt/api/.venv/bin/python /opt/api/bin/manage.py migrate
sudo certbot --nginx -d yourdomain.com
sudo systemctl enable --now mojo-asgi
```

## What's Included

### `bin/` — Management scripts
| Script | Purpose |
|--------|---------|
| `manage.py` | Django management + `sync_schema`, `routes` |
| `run_tests` | testit test runner (auto-activates venv) |
| `cron.py` | Cron daemon (`--run`, `--list`, `--daemon`) |
| `jobman` | Async job engine + scheduler manager |
| `jobs.py` | Job queue CLI |
| `tasks.py` | Task runner |
| `versioning` | Semantic version bumping |
| `setup_local_postgres` | Local DB bootstrap |
| `_asgi.py` / `_wsgi.py` | ASGI/WSGI entry points |

### `config/settings/` — Profile-based settings
| Profile | Path | Usage |
|---------|------|-------|
| Defaults | `defaults/` | Shared across all profiles |
| Local | `local/` | Development (`var/profile` = "local") |
| Test | `test/` | CI/testing |
| Production | `prod/` | AWS deployment |

### `aws/` — Deployment infrastructure
| File | Purpose |
|------|---------|
| `ec2_bootstrap.sh` | System-level EC2 setup (curl one-liner, no repo needed) |
| `ec2_deploy.sh` | Project-specific setup (after git clone) |
| `post_pull.sh` | Post-deployment updates |
| `deploy.py` | AWS infrastructure provisioning (SG, RDS, ElastiCache, EC2) |
| `nginx/` | Full nginx config with TLS, security headers, bot blocking |
| `nginx/systemd/` | systemd service files |

### `.claude/rules/` — Claude Code conventions
Framework-specific rules for AI-assisted development. Ensures consistent code patterns.

## Deployment Architecture

```
                    ┌─────────────────────┐
                    │     nginx (443)      │
                    │  TLS + security hdrs │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                 │
        /api/ + /ws/      /static/          /.well-known/
              │                │                 │
    ┌─────────▼─────────┐     │           certbot webroot
    │  mojo-asgi.service │     │
    │  uvicorn (4 workers)│    │
    │  unix socket        │    │
    └─────────────────────┘  /opt/api/django/static/

    ┌───────────────────────────────────────────┐
    │  cron.d/2_mojo_cron   → bin/cron.py --run │
    │  cron.d/3_mojo_jobs   → bin/jobman start  │
    └───────────────────────────────────────────┘
```

## License

Apache 2.0

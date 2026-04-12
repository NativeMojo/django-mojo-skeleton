# My Mojo Project

Built on [django-mojo](https://github.com/NativeMojo/django-mojo).

## Quick Reference

```bash
# Activate venv
source .venv/bin/activate

# Django management
.venv/bin/python ./bin/manage.py <command>

# Run dev server (ASGI via Uvicorn, auto-generates var/dev_server.conf on first run)
./bin/run_dev_server

# Run tests
bin/run_tests -t test_module.filename

# Sync schema (makemigrations + migrate)
.venv/bin/python ./bin/manage.py sync_schema

# Version bump
./bin/versioning rev
```

## Architecture

### App Structure
```
apps/my_app/myapp/          # Your main app
  models/                   # One model per file
  rest/                     # One handler per file
  services/                 # Business logic
  management/commands/      # Django management commands
```

## Database
- PostgreSQL with local dev on localhost:5432
- Cache: Redis on localhost:6379

## Conventions
See `.claude/rules/` for detailed conventions. Key points:
- No Python type hints
- `request.DATA` for all input (never request.POST/GET)
- One model per file, one REST handler per file
- Business logic in services/, not models or handlers
- `import mojo.decorators as md` for REST decorators
- RestMeta on every model with REST access
- Permissions enforced on every endpoint

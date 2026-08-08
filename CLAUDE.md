# Django-Mojo Project

Django backend built on [django-mojo](https://github.com/NativeMojo/django-mojo). Django-mojo is a
convention-heavy framework: you get automatic REST CRUD, declarative permissions, serialization,
search, aggregation, audit logging, and lifecycle hooks **for free** — but only if you use its
models. Fighting the framework (hand-rolled serializers, manual permission checks, domain data
stuffed into built-in models) throws all of that away. Build **with** the grain.

## Read Before Building

1. The reference app: `apps/examples/todo/` — a complete feature (`models.py` + `rest.py`) in ~2
   files with zero boilerplate. **This is what a mojo feature is supposed to look like.** Read it
   before adding any new feature, then delete it once you've got your own apps.
2. Framework references (source of truth for behavior — online, link don't copy):
   - [mojo_model.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/mojo_model.md) — MojoModel, RestMeta, lifecycle hooks, actions
   - [graphs.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/graphs.md) — serialization graphs (replaces hand-written serializers)
   - [permissions.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/permissions.md) + [rest/permissions.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/rest/permissions.md)
   - [django_developer/README.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/README.md) — index of every built-in app; don't reinvent what exists

## Work Tracking

Work lives on the Maestro board configured by `.claude/maestro.json` (NativeMojo workspace,
project `django-mojo-skeleton`). Pick the smallest matching workflow:

- File work → `/maestro-task`
- Investigate and plan an item → `/maestro-scope`
- Build a planned item → `/maestro-build`
- Scope and build a batch behind one approval gate → `/maestro-auto`
- Make a small, low-risk, single-session change → `/maestro-vibe`
- Draft the next release note → `/maestro-release-note`

If Maestro is unavailable or unauthenticated, say so explicitly. Do not silently switch to a
different work record.

## The One Rule That Matters Most

**Domain data gets a real MojoModel.** If your feature has a "thing" (an order, an application, an
article, an invite), that thing is a `models.Model, MojoModel` subclass with a `RestMeta` — not a
dict shoved into a built-in's `metadata` JSON, not a hand-written `_serialize()` function, not a
service that manually checks `if x.user_id != user.pk`. See `.claude/rules/architecture.md` for the
full decision guide and the anti-patterns to avoid. This is the single most common way mojo projects
drift off-framework — the framework's power is in the models, so skipping them forfeits it.

## Conventions (auto-loaded rules)

These load automatically — follow them. Highlights:
- **Model-first**: domain entities are MojoModels with RestMeta (`@architecture`, `@models`)
- **Thin handlers**: `rest/` handlers delegate; `Model.on_rest_request(request, pk)` for CRUD
- **`request.DATA`** for all input — never `request.POST` / `request.GET`
- **No Python type hints** anywhere in new code
- **One model per file, one REST handler per file**
- **Permissions declared in RestMeta**, not hand-checked in services
- **No manual migration files** — `.venv/bin/python ./bin/manage.py makemigrations <app>`

@.claude/rules/core.md
@.claude/rules/architecture.md
@.claude/rules/models.md
@.claude/rules/api.md
@.claude/rules/testing.md
@.claude/rules/docs.md

## Quick Reference

```bash
source .venv/bin/activate                              # activate venv
.venv/bin/python ./bin/manage.py <command>             # Django management
./bin/run_dev_server                                   # dev server (ASGI/Uvicorn)
bin/run_tests -t test_module.filename                  # run tests
.venv/bin/python ./bin/manage.py sync_schema           # makemigrations + migrate
.venv/bin/python ./bin/manage.py makemigrations <app>  # after model changes
./bin/versioning rev                                   # version bump
```

## App Structure

```
apps/<app>/<app>/
  models/                   # one MojoModel per file  ← domain data lives HERE
  rest/                     # one thin handler per file
  services/                 # cross-model orchestration only (not a substitute for models)
  management/commands/      # Django management commands
```

## Infrastructure

- PostgreSQL (localhost:5432), Redis cache (localhost:6379)
- `import mojo.decorators as md` for REST decorators

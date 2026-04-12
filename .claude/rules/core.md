# Core Rules

These rules apply to all work in this repository. Non-negotiable.

## KISS

The simplest correct solution wins. No abstractions for one-time operations. No over-engineering. Match existing patterns in the target app before introducing new ones.

## Input Handling

- **`request.DATA`** for all input. Never `request.POST` or `request.GET`.
- `request.DATA` is a unified accessor (GET + POST + JSON merged into an `objict`).

## Forbidden Actions

- **No Python type hints.** Anywhere in new code.
- **No manual migration files.** Run `.venv/bin/python ./bin/manage.py makemigrations <app>`.
- **Never expose secrets or sensitive internals in REST graphs.**
- Never make blind edits — read target files first.
- Never use `mojo.helpers.threadlocals` — use `self.active_request` (MojoModel property) instead.

## Security

- **Fail-closed permissions.** Every endpoint must enforce permissions via `RestMeta` or decorators.
- Secrets use `MojoSecrets`. Inherit `MojoSecrets, MojoModel` (no `models.Model`).

## Organization

- **One model per file, one REST handler per file.**
- **Domain logic in `app/services/`.** Not in models or REST handlers.
- For per-instance operations, prefer `POST_SAVE_ACTIONS` + `on_action_<name>` over custom endpoints.

## Framework Auto-Wrap Gotcha

Dict responses are auto-wrapped as `{status: True, data: RESP}` when: no `status` key, no `data` key, and `resp.get("error") is None`. If your domain data has a `status` field (e.g., domain whois), rename it (e.g., `registration_status`) before returning.

## Trust Order

1. Online django-mojo docs (source of truth for framework behavior)
2. `CLAUDE.md` and `.claude/rules/` (project rules)
3. Existing code patterns in the target app

## Delivery Checklist

1. Code follows conventions above
2. Tests added/updated where needed
3. Docs updated for both tracks when behavior changed
4. `CHANGELOG.md` updated if behavior or API changed
5. Final summary: what changed, why, commands to validate

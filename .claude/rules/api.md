---
globs: apps/**/rest/**/*.py,apps/**/rest/*.py
---

# REST API Conventions

Reference: [mojo_model.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/mojo_model.md)
and [rest/permissions.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/rest/permissions.md).
Canonical example: `apps/examples/todo/rest.py`.

## Handlers Are Thin — Delegate to the Model

The default handler routes straight to the model's auto-CRUD. Do **not** hand-write list/get/create/
update/delete logic, serialization, or permission checks in the handler — the model does all of it:

```python
import mojo.decorators as md
from ..models.article import Article

@md.URL('article')
@md.URL('article/<int:pk>')
def on_article(request, pk=None):
    return Article.on_rest_request(request, pk)
```

This one handler gives GET-list (paginated + `?search=` + `_mode` aggregation), GET-one, POST create,
POST/PUT update, and DELETE — all permission-gated by `RestMeta`. Reach for a custom `@md.GET`/`@md.POST`
handler only for genuine non-CRUD operations, and prefer `POST_SAVE_ACTIONS` + `on_action_<name>` for
per-instance operations. Return plain dicts — the framework wraps them (never `JsonResponse`).

## URL Decorators

- `@md.URL('resource')`, `@md.GET('resource')`, `@md.POST('resource')`
- **Exclude the app prefix.** `@md.GET("phone/confirm")` → `/api/verify/phone/confirm`
- `@md.GET("verify/phone/confirm")` → `/api/verify/verify/phone/confirm` (double prefix)

## Path Parameters

- Dynamic path params go at the **end** of URL paths only.
- `@md.POST("sharing/grant/<int:pk>")` — correct
- `@md.POST("connections/<int:pk>/sharing/grant")` — incorrect

## Input

- Always `request.DATA` — never `request.POST` or `request.GET`.

## Permissions

- Every endpoint must enforce permissions via `RestMeta` (preferred) or `@md.requires_perms`.
- `requires_perms` auth flow: fails direct perm check → falls back to group check via
  `request.DATA["group"]` → `group.user_has_permission()`.

## Authentication Methods

| Method | Format | Used By |
|--------|--------|---------|
| API Key | `Authorization: apikey mvp-XXXXX` | Admin/service endpoints |
| Session Token | `ident-XXXXX` in request.DATA | Identity sessions |
| OAuth 2.0 + PKCE | Standard OAuth flow | Third-party integrations |

---
globs: apps/**/models/**/*.py,apps/**/models/*.py
---

# Model Conventions

Reference: [mojo_model.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/mojo_model.md)
(RestMeta table, lifecycle hooks, actions) and
[graphs.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/graphs.md)
(serialization). Canonical example: `apps/examples/todo/models.py`.

**Domain data is a MojoModel — never a dict in a built-in's `metadata` JSON.** See
`.claude/rules/architecture.md` for the decision guide and anti-patterns.

## Inheritance

- Regular models: `models.Model, MojoModel` (in that order)
- Secret-bearing models: `MojoSecrets, MojoModel` (no `models.Model` — MojoSecrets provides it)

## File Organization

- One model per file, in `app/models/`
- Include timestamps:
  - `created = models.DateTimeField(auto_now_add=True, editable=False, db_index=True)`
  - `modified = models.DateTimeField(auto_now=True, db_index=True)`
- Add `user` (`account.User`) and/or `group` (`account.Group`) FKs where access control needs them.

## Minimal Template

```python
from django.db import models
from mojo.models import MojoModel

class Article(models.Model, MojoModel):
    user = models.ForeignKey("account.User", null=True, on_delete=models.SET_NULL)
    group = models.ForeignKey("account.Group", null=True, on_delete=models.SET_NULL)
    title = models.CharField(max_length=255)
    body = models.TextField(blank=True, default="")
    created = models.DateTimeField(auto_now_add=True, editable=False, db_index=True)
    modified = models.DateTimeField(auto_now=True, db_index=True)

    class RestMeta:
        VIEW_PERMS = ["view_articles", "owner"]
        SAVE_PERMS = ["manage_articles", "owner"]
        SEARCH_FIELDS = ["title", "body"]
        LOG_CHANGES = True
        GRAPHS = {
            "list": {"fields": ["id", "title", "created"]},
            "default": {
                "fields": ["id", "title", "body", "created", "modified"],
                "graphs": {"user": "basic"},
            },
        }
```

## RestMeta

Every model with REST access defines `RestMeta`:
- `VIEW_PERMS` / `SAVE_PERMS` — enforcement (include `"owner"` for FK-based owner access)
- `GRAPHS` — serialization shapes (client selects via `?graph=`); this **replaces** hand-written serializers
- `NO_SHOW_FIELDS` — hide sensitive fields globally; `NO_SAVE_FIELDS` — block client writes
- `SEARCH_FIELDS` — `?search=` support; `LOG_CHANGES = True` — audit trail
- `POST_SAVE_ACTIONS` + `on_action_<name>` — per-instance operations (prefer over custom endpoints)

## Lifecycle & Field Hooks

Put per-save logic on the model, not in the handler:
`on_rest_pre_save(self, changed_fields, created)`, `on_rest_saved(...)`, `on_rest_created(self)`,
`on_rest_pre_delete(self)`, and `set_<field>(self, value)` for field-level validation.

## Permissions & Protected JSON

- `PROTECTED_JSON_PERMS` guards the `"protected"` root key of any JSONField (e.g. `Group.metadata.protected`).
- Read protected config: `group.get_metadata().get("protected.verify")` → objict.

## Group Members

```python
member = group.add_member(user)            # no permissions kwarg
member.add_permission(["perm1", "perm2"])  # separate call
```

## Access Current Request

Use `self.active_request` (MojoModel property) — NOT `mojo.helpers.threadlocals`.

# Model Conventions

## Inheritance

- Regular models: `models.Model, MojoModel` (in that order)
- Secret-bearing models: `MojoSecrets, MojoModel` (no `models.Model`)

## File Organization

- One model per file
- Models live in `app/models/` directory

## RestMeta

Every model with REST access must define `RestMeta` with:
- `VIEW_PERMS` / `SAVE_PERMS` for permission enforcement
- `GRAPHS` for serialization shapes (client requests via `?graph=basic`)
- `NO_SHOW_FIELDS` to hide sensitive fields
- `SEARCH_FIELDS` for search support
- `POST_SAVE_ACTIONS` for per-instance operations

## Permissions

- `PROTECTED_JSON_PERMS = ["admin_compliance", "admin_verify"]` for Group.metadata.protected
- Read protected config: `group.get_metadata().get("protected.verify")` → objict

## Group Members

```python
member = group.add_member(user)            # no permissions kwarg
member.add_permission(["perm1", "perm2"])  # separate call
```

## Access Current Request

Use `self.active_request` (MojoModel property), NOT `mojo.helpers.threadlocals`.

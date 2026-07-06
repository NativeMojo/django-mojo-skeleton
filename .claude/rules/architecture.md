---
globs: apps/**/*.py
---

# Architecture: Model-First, Not Service-First

Django-mojo is a **model-driven** framework. The model is the API. Before writing any feature,
decide where the data lives — and default to a real model. Getting this decision wrong is the most
common way mojo projects drift into hand-rolled serializers and manual permission checks.

## The Decision: Model vs. Service vs. Built-in

**Does the feature introduce a domain "thing" with its own fields, ownership, or lifecycle?**
(an order, an application, an article, an invite, a submission, a review…)

→ **Yes: create a `models.Model, MojoModel` subclass with a `RestMeta`.** One model per file in
`app/models/`. Route it with a thin `Model.on_rest_request(request, pk)` handler. This gives you
CRUD, permissions, serialization graphs, search, pagination, aggregation, and audit logging with
almost no code. See `apps/examples/todo/` and the
[MojoModel reference](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/mojo_model.md).

→ **No — it's an operation that spans several existing models** (provisioning a group + members +
sending a message, an OAuth/webhook handshake, a batch import): put it in `app/services/`. Services
are for **orchestration**, not for standing in for a model you didn't want to create.

→ **It genuinely is an existing built-in** (a `fileman.File`, an `account.Group`): use the built-in
directly. But the moment you find yourself adding domain fields to its `metadata` JSON and filtering
on them, you have a domain thing — go back to the first branch and make a model (a model can still
`ForeignKey` the built-in).

## Anti-Patterns — Do Not Do These

These are the exact shortcuts that take a project off-framework. If you're about to write one, stop
and create a MojoModel instead.

1. **Overloading a built-in's JSON `metadata` as a fake table.**
   `File.objects.filter(metadata__is_order=True)` with `total`/`status`/`items` stuffed in the blob
   is a domain model in disguise. JSON metadata can't be indexed, migrated, validated, or efficiently
   queried, and it's invisible to graphs, search, and aggregation. Make an `Order(models.Model, MojoModel)`.

2. **Hand-writing a `_serialize()` / `to_dict()` helper.** That is precisely what `RestMeta.GRAPHS`
   does — declaratively, with nested relations, field protection, and CSV export. If you're mapping a
   model to a dict by hand, you skipped the graph. See
   [graphs.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/core/graphs.md).

3. **Manual permission checks in service functions**
   (`if f.user_id != user.pk: raise PermissionDeniedException(...)`). This scatters security across
   functions and it's opt-in — forget one and the endpoint is wide open. Declare `VIEW_PERMS` /
   `SAVE_PERMS` (with `"owner"`) on the model and let the framework enforce it fail-closed. See
   [rest/permissions.md](https://github.com/NativeMojo/django-mojo/blob/main/docs/django_developer/rest/permissions.md).

4. **Hand-rolled field whitelists** (`ALLOWED_FIELDS = [...]` then looping to copy allowed keys).
   `RestMeta` `NO_SAVE_FIELDS` / `set_<field>` methods already gate what a client may write.

## What You Lose By Going Off-Framework

Every hand-rolled shortcut silently gives up things you'd otherwise get for free: declarative
fail-closed security, serialization graphs, `?search=`, pagination + `_mode` aggregation, `LOG_CHANGES`
audit trails, DB indexing + migrations, batch create/update, and lifecycle hooks
(`on_rest_pre_save`, `on_action_<name>`). A web-mojo admin frontend's tables/forms also consume graph
output directly — hand-rolled dicts don't line up.

## When A Service IS Correct

Services are right for logic that legitimately coordinates multiple models or external systems and
has no single owning row: provisioning, third-party integrations, invite/claim flows. Keep them thin,
keep the domain data in models, and let services call `Model.create_from_dict()` / `instance.to_dict()`
rather than re-implementing serialization.

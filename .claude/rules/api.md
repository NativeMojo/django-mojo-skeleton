# REST API Conventions

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

## Handler Organization

- One REST handler per file
- Handlers are thin — delegate to `app/services/` for business logic

## Permissions

- Every endpoint must enforce permissions via `RestMeta` or `@md.requires_perms`
- `requires_perms` auth flow: fails direct perm check → falls back to group check via `request.DATA["group"]` → `group.user_has_permission()`

## Authentication Methods

| Method | Format | Used By |
|--------|--------|---------|
| API Key | `Authorization: apikey mvp-XXXXX` | Admin/service endpoints |
| Session Token | `ident-XXXXX` in request.DATA | Identity sessions |
| OAuth 2.0 + PKCE | Standard OAuth flow | Third-party integrations |

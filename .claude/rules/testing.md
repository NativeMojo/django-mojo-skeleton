---
globs: apps/tests/**/*.py,apps/**/tests/**/*.py
---

# Testing Conventions

Before writing any test, read `docs/django_developer/testit/Overview.md`. This is mandatory.

## Framework
- Use testit: `from testit import helpers as th`
- Decorator: `@th.django_unit_test()`
- Function signature: `def test_xxx(opts):`
- Tests go in `tests/` directory (NOT inside the package)
- Import the module under test inside the test function

## Server Isolation
- `opts.client` calls a **separate server process** — `mock.patch` and `override_settings` have NO effect on the server
- Use `th.server_settings(**overrides)` for Django settings overrides
- Never use `override_settings` in testit tests

## Rules
- Every `assert` must include a descriptive failure message — no bare asserts
- Tests must pass when the feature is correct and fail when it is broken
- Never write tests that assert the feature is absent or broken
- Setup functions must clean up test data before creating it
- Run with `bin/run_tests -t test_module.filename` — do not ask the user to run them
- This is a django-mojo consumer project: run its full application suite with
  `bin/run_tests --nomojo`. Never run django-mojo's framework suites here; the
  django-mojo repository already owns and validates them.
- If a test fails, fix the **code** (not the test) unless the test itself is wrong

## Test Location

- `apps/tests/test_<name>/` with numbered files (e.g., `1_test_models.py`, `2_test_api.py`)

## Critical: Real HTTP Requests

Tests make **real HTTP requests** to a running dev server on port 9009. `unittest.mock.patch()` does NOT affect the server. Always check port 9009 before running tests.

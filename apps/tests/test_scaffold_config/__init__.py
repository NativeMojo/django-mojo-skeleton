"""Scaffold-config tests for this django-mojo consumer.

This is a worked example of a tiered testit package. testit groups tests into
BUCKETS and runs a named PRESET (a set of buckets):

    core       - the fast baseline every consumer runs (a bare `bin/run_tests`).
                 Strictest isolation: no shared-state mutation, parallel-safe,
                 cold_budget 0. Keep it small and green.
    framework  - the rest of your critical, parallel-safe tests (this package).
    bug        - one isolated regression per fixed bug.
    extended / admin / edge / slow - opt-in buckets, run only when selected.

A bare `bin/run_tests` selects the preset named by "default_preset" in
apps/tests/testit.json (this skeleton sets it to "framework" so a bare run runs
these tests instead of nothing). `--tier framework` and `--tier all` widen it.
See docs/django_developer/testit/Tiers.md in django-mojo for the buckets, the
core-eligibility checklist, and the parallel-safety contract.

Scaffold more packages with:  ./bin/run_tests --init <package_name>

Consumer test runners do NOT flush the database or Redis between runs, so every
setup function must delete the rows it is about to create before creating them.
"""

TESTIT = {"tier": "framework"}

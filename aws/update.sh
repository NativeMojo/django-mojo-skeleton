#!/bin/bash
# The canonical django-mojo update shim. See the framework's
# docs/django_developer/deploy/README.md, "The shim contract".
#
# Locate-or-FATAL, with no var/deploy fallback: update.sh is the entry the
# fleet deploy plane invokes, and running a stale snapshot of it is how a node
# speaks an older deploy contract than the orchestrator driving it — which
# surfaces minutes later as "the canary never reported", naming nothing.
#
# This file used to be a full 208-line copy. Project deltas belong on the
# comment line below as exported variables, not in a fork.
#
# project deltas, e.g.: export SANITY_URL="http://127.0.0.1:8080/api/version"
target="$(python3 -m mojo.deploy locate update.sh)" \
    || { echo "FATAL: django-mojo is not installed — cannot run update.sh" >&2; exit 1; }
exec bash "$target" "$@"

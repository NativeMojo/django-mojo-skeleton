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
# PROJECT DELTAS GO HERE as exports, above the locator.
#
# The one you will almost certainly need is PROBE_URL — the health check the
# deploy runs after restarting the API. It MUST be exported in THIS file:
# the packaged update.sh passes it into the transient deployment unit with
# --setenv, and that unit runs a SNAPSHOT of the packaged post_deploy, so an
# export made in aws/post_deploy.sh is read after the value is already fixed
# and never applies.
#
# The packaged default is https://127.0.0.1/api/version. A node whose nginx
# has no vhost for the literal IP fails TLS SNI ("unrecognized name") and curl
# returns 000 — which fails the candidate probe AND the rollback probe, so a
# perfectly healthy API reports "previous API did not return HTTP 200" and the
# deploy leaves a retained transaction. Point it at a name the node can
# actually resolve and terminate TLS for.
#
# export PROBE_URL="https://api.example.com/api/version"
#
# (SANITY_URL, which this line used to name, is read by nothing in the current
# contract. It looked like a configured probe while doing nothing at all.)
target="$(python3 -m mojo.deploy locate update.sh)" \
    || { echo "FATAL: django-mojo is not installed — cannot run update.sh" >&2; exit 1; }
exec bash "$target" "$@"

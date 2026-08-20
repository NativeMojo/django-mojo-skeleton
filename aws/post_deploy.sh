#!/bin/bash
# The canonical django-mojo post_deploy shim. See the framework's
# docs/django_developer/deploy/README.md, "The shim contract".
#
# This file used to be a full 155-line copy of the framework's script. A fork
# stops receiving framework fixes the moment it is made, and nothing announces
# that — it just quietly runs an older deploy every release, until the day a
# framework change it never received matters. Project deltas belong on the
# comment line below as exported variables, not in a copy.
#
# project deltas, e.g.: export SANITY_URL="http://127.0.0.1:8080/api/version"
target="$(python3 -m mojo.deploy locate post_deploy.sh)" \
    || target="${PROJ_PATH:-/opt/api}/var/deploy/post_deploy.sh"
[ -f "$target" ] || { echo "FATAL: django-mojo is not installed and no snapshot exists — cannot run post_deploy (provisioning installs the framework first)" >&2; exit 1; }
exec bash "$target" "$@"

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
# PROJECT DELTAS GO HERE as exports — but NOT PROBE_URL.
#
# post_deploy runs inside the transient deployment unit, whose environment
# update.sh has already fixed via --setenv. Exporting PROBE_URL here is read
# too late and silently has no effect. Set it in aws/update.sh instead.
#
# (SANITY_URL, which this line used to name, is read by nothing in the current
# contract.)
target="$(python3 -m mojo.deploy locate post_deploy.sh)" \
    || target="${PROJ_PATH:-/opt/api}/var/deploy/post_deploy.sh"
[ -f "$target" ] || { echo "FATAL: django-mojo is not installed and no snapshot exists — cannot run post_deploy (provisioning installs the framework first)" >&2; exit 1; }
exec bash "$target" "$@"

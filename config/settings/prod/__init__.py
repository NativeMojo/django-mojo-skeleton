from .db import *

DEBUG = False
ALLOW_ADMIN_SITE = False
ADMIN_SITE_PREFIX = 'not_allowed'
API_METRICS = True
API_METRICS_GRANULARITY = "minutes"

REST_AUTO_PREFIX = True

METRICS_TIMEZONE = "America/Los_Angeles"

MOJO_REST_LIST_PERM_DENY = False

LOGIT_DB_ALL = False
LOGIT_FILE_ALL = False
LOGIT_RETURN_REAL_ERROR = True
LOGIT_MAX_RESPONSE_SIZE = 1024
LOGIT_NO_LOG_PREFIX = ['/api/']
LOGIT_ALWAYS_LOG_PREFIX = ['POST:/api/user/', 'POST:/api/group/', 'POST:/api/logs']
LOGIT_ASYNC_LOGGING = True

MOJO_APP_STATUS_200_ON_ERROR = False

# ── Fleet code deploy (django-mojo edge deploy plane) ────────────────────────
# Prod profile ONLY, on purpose: django-mojo ships no EDGE_DEPLOY_SCRIPT
# default so an unconfigured box (dev laptop, CI) refuses to run a deploy —
# putting this in defaults/ would arm every checkout. Read with get_static,
# so a DB Setting row can never control the argv. No sudo wrapper: the job
# engine runs as ec2-user, which owns the clone; update.sh sudos
# post_deploy.sh itself.
EDGE_DEPLOY_SCRIPT = ["/opt/api/aws/update.sh"]
EDGE_DEPLOY_BRANCH = "main"
# This deployment installs mojo.apps.edge for the DEPLOY plane only — nginx
# is owned by aws/post_deploy.sh, not the edge vhost-convergence sweep, for
# as long as convergence is off.
#
# The node-side prerequisites are provisioned anyway (aws/ec2_deploy.sh):
# /etc/sudoers.d/mojo-edge, the /etc/nginx/conf.d/mojo.conf include, and an
# ec2-user-owned var/edge. That is deliberate — turning the certificate and
# vhost plane on is then a settings edit, not a second manual pass over every
# node. Two consequences worth knowing first: with convergence ON,
# post_deploy.sh's `nginx -t || die` gates code deploys on the live config
# including edge generations; and post_deploy.sh does not distribute conf.d,
# so a node provisioned before this change needs aws/ec2_deploy.sh re-run
# before it can opt in. See docs/django_developer/deployment/provisioning.md.
EDGE_CONVERGE_ENABLED = False
# EDGE_RESERVED_SERVER_NAMES = ["api.example.com"]   # REQUIRED before enabling
# convergence — it fails closed: with ALLOWED_HOSTS = ["*"] and this unset, no
# vhost can be enabled at all.

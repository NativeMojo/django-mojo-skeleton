from .db import *

DEBUG = False

MEDIA_HOST = "http://localhost:9009"

ALLOW_ADMIN_SITE = False
ADMIN_SITE_PREFIX = 'not_allowed'
API_METRICS = True
API_METRICS_GRANULARITY = "minutes"

METRICS_TIMEZONE = "America/Los_Angeles"
MOJO_REST_LIST_PERM_DENY = False

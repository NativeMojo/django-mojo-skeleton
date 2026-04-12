from mojo.helpers import paths

# ── Logging Configuration ────────────────────────────────────────────────────

LOGIT_DB_ALL = True
LOGIT_FILE_ALL = False
LOGIT_MAX_RESPONSE_SIZE = 1024
LOGIT_NO_LOG_PREFIX = ['/api/']
LOGIT_ALWAYS_LOG_PREFIX = ['POST:/api/user/', 'POST:/api/group/', 'POST:/api/logs']
LOGIT_ASYNC_LOGGING = True
LOGIT_QUEUE_MAXSIZE = 1000
LOGIT_RETURN_REAL_ERROR = False

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
}

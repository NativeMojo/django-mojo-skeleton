
# ── Async Job Engine ─────────────────────────────────────────────────────────

# THIS LIST REPLACES THE FRAMEWORK'S DEFAULTS — it does not extend them. Every
# channel django-mojo publishes to must appear here or the work is queued and
# never consumed, with no error anywhere: the publisher succeeds, the job sits
# in a stream nobody reads.
#
# That is not hypothetical. This list once held only the seven project channels
# below the fold, and the missing 'edge' meant `platform_deploy.edge_roster()`
# found no runner consuming it — so every push webhook on every project built
# from this skeleton answered 503 "edge runner roster unavailable" and
# push-to-deploy did nothing, forever.
#
# The first block mirrors django-mojo's own `mojo.apps.jobs.DEFAULT_CHANNELS`.
# It is written out rather than imported because settings load before the app
# registry does. When a django-mojo upgrade adds a channel, add it here too —
# `aws/check_node.py` reports the ones this box is missing.
JOBS_CHANNELS = [
    # django-mojo's framework channels
    'default', 'priority', 'cleanup',
    'incident_handlers', 'renditions', 'certs',
    'webhooks', 'webhook_fanout',
    'edge',
    # this project's own
    'email', 'media', 'metrics',
]

JOBS_DEFAULT_MAX_RETRIES = 0
JOBS_ENGINE_MAX_WORKERS = 10
JOBS_ENGINE_CLAIM_BUFFER = 2
JOBS_ENGINE_CLAIM_BATCH = 5
JOBS_RUNNER_HEARTBEAT_SEC = 5
JOBS_IDLE_TIMEOUT_MS = 60000
JOBS_PAYLOAD_MAX_BYTES = 1048576
JOBS_STREAM_MAXLEN = 100000
JOBS_DEFAULT_BACKOFF_BASE = 2.0
JOBS_DEFAULT_BACKOFF_MAX = 3600
JOBS_REDIS_PREFIX = 'mojo:jobs'
JOBS_WEBHOOK_MAX_RETRIES = 5
JOBS_WEBHOOK_MAX_TIMEOUT = 300
JOBS_WEBHOOK_DEFAULT_TIMEOUT = 10

JOBS_LOCAL_QUEUE_MAXSIZE = 10

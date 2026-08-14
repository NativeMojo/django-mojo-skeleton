# Production database configuration
#
# Credentials come from var/django.conf. django-mojo's config loader sets flat
# settings globals only — nothing maps DATABASE_* into the DATABASES dict — so
# this profile reads the conf itself and builds the dicts from it.
#
# Expected var/django.conf keys (written by aws/deploy.py's managed block):
#   DATABASE_HOST, DATABASE_PORT, DATABASE_NAME, DATABASE_USER,
#   DATABASE_PASSWORD, REDIS_SERVER, REDIS_PORT
from mojo.helpers.settings.parser import DjangoConfigLoader

_conf = {}
DjangoConfigLoader().load_config(_conf)

REDIS_SERVER = _conf.get("REDIS_SERVER", "")
REDIS_PORT = _conf.get("REDIS_PORT", 6379)

CACHES = {
    "default": {
        "BACKEND": "mojo.cache.MojoRedisCache",
        "TIMEOUT": 300,
        "KEY_PREFIX": "mojo",
        "LOCATION": f"{REDIS_SERVER}:{REDIS_PORT}",
    }
}

WS4REDIS_CONNECTION = {
    'host': REDIS_SERVER,
    'port': REDIS_PORT,
}

SESSION_REDIS = {
    'host': REDIS_SERVER,
    'port': REDIS_PORT,
}

DATABASE_ROUTERS = []

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql_psycopg2',
        'NAME': _conf.get("DATABASE_NAME", ""),
        'USER': _conf.get("DATABASE_USER", ""),
        'PASSWORD': _conf.get("DATABASE_PASSWORD", ""),
        'HOST': _conf.get("DATABASE_HOST", ""),
        'PORT': str(_conf.get("DATABASE_PORT", "5432")),
        'OPTIONS': {'sslmode': 'allow'}
    },
}

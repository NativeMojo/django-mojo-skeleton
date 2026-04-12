# Production database configuration
#
# Credentials should come from var/django.conf overrides, not hardcoded here.
# This file defines the structure; var/django.conf provides the values.
#
# Example var/django.conf:
#   DATABASE_HOST = "your-rds-endpoint.region.rds.amazonaws.com"
#   DATABASE_PORT = "5432"
#   DATABASE_NAME = "my_mojo_project"
#   DATABASE_USER = "postgres"
#   DATABASE_PASSWORD = "your-password"
#   REDIS_HOST = "your-cache-endpoint.cache.amazonaws.com"
#   REDIS_PORT = "6379"

REDIS_SERVER = ""       # Set via var/django.conf -> REDIS_HOST
REDIS_PORT = 6379       # Set via var/django.conf -> REDIS_PORT

CACHES = {
    "default": {
        "BACKEND": "mojo.cache.MojoRedisCache",
        "TIMEOUT": 300,
        "KEY_PREFIX": "mojo",
        "LOCATION": "localhost:6379",  # Overridden by var/django.conf
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
        'NAME': '',          # Set via var/django.conf -> DATABASE_NAME
        'USER': '',          # Set via var/django.conf -> DATABASE_USER
        'PASSWORD': '',      # Set via var/django.conf -> DATABASE_PASSWORD
        'HOST': '',          # Set via var/django.conf -> DATABASE_HOST
        'PORT': '5432',
        'OPTIONS': {'sslmode': 'allow'}
    },
}

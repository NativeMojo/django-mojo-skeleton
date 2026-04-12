
# Test database configuration
# Defaults to same as local. Override here for CI or isolated test DB.

REDIS_HOST = ""
REDIS_PORT = "6379"

REDIS_DB = {
    "host": REDIS_HOST,
    "port": REDIS_PORT
}

DATABASES = {
    # Empty = uses default from local/db.py
    # Override for CI:
    # 'default': {
    #     'ENGINE': 'django.db.backends.postgresql',
    #     'NAME': 'my_mojo_project_test',
    #     'USER': 'mojo_test',
    #     'HOST': 'localhost',
    #     'PORT': '5432',
    # }
}

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
        'LOCATION': 'test-cache',
    }
}

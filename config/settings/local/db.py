from mojo.helpers import paths

REDIS_DB = {
    "host": "localhost",
    "port": "6379"
}

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'my_mojo_project',       # <-- change to your project db name
        'USER': 'mojo_test',
        'HOST': 'localhost',
        'PORT': '5432',
    }
}

WS4REDIS_CONNECTION = {
    'host': REDIS_DB["host"],
    'port': REDIS_DB["port"],
}

CACHES = {
    "default": {
        "BACKEND": "mojo.cache.MojoRedisCache",
        "TIMEOUT": 300,
        "KEY_PREFIX": "mojo",             # <-- change to your project prefix
        "LOCATION": "localhost:6379",
    }
}

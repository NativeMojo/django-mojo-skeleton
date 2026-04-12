
# ── Middleware ────────────────────────────────────────────────────────────────
MIDDLEWARE = [
    'mojo.middleware.cors.CORSMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'mojo.middleware.mojo.MojoMiddleware',
    'mojo.middleware.auth.AuthenticationMiddleware',
    'mojo.middleware.logging.LoggerMiddleware',
]

# Custom bearer token handlers (add your own auth mechanisms here)
AUTH_BEARER_HANDLERS = {
    # "custsess": "myapp.models.CustomerSession.validate",
}

# Map bearer name to request attribute
AUTH_BEARER_NAME_MAP = {
    "bearer": "user",
    "apikey": "user",
}

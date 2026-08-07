"""
Default Settings

Shared across all profiles (local/test/prod).
Add new default modules here and import with *.
"""

from mojo.helpers import paths

from .email import *
from .logging import *
from .middleware import *
from .incident import *
from .jobs import *

# Define the base directory of the project
BASE_DIR = paths.PROJECT_ROOT

# ── Security ──────────────────────────────────────────────────────────────────
ALLOW_ADMIN_SITE = False

DEBUG = False

ALLOWED_HOSTS = ['*']

APPEND_SLASH = False

AUTH_USER_MODEL = "account.User"

SITE_ID = 1

# ── URL Configuration ────────────────────────────────────────────────────────
ROOT_URLCONF = 'settings.urls'

# ── Templates ─────────────────────────────────────────────────────────────────
TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / "templates"],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

# ── Password Validation ──────────────────────────────────────────────────────
AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# ── Internationalization ─────────────────────────────────────────────────────
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_L10N = True
USE_TZ = True

# ── Static & Media ───────────────────────────────────────────────────────────
STATIC_URL = '/static/'
STATIC_ROOT = paths.VAR_ROOT / "static"
SITE_STATIC_ROOT = paths.VAR_ROOT / "site_static"

MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / "media"

STATICFILES_DIRS = [SITE_STATIC_ROOT]

# ── Primary Key ──────────────────────────────────────────────────────────────
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# ── Caching ──────────────────────────────────────────────────────────────────
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
        'LOCATION': 'unique-cache-key',
    }
}

# ── Sessions ─────────────────────────────────────────────────────────────────
SESSION_ENGINE = 'django.contrib.sessions.backends.db'
SESSION_COOKIE_AGE = 1209600  # 2 weeks

# ── CSRF & Security Headers ─────────────────────────────────────────────────
CSRF_TRUSTED_ORIGINS = ""
SECURE_BROWSER_XSS_FILTER = True
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SECURE_SSL_REDIRECT = False
SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False

# ── CORS ─────────────────────────────────────────────────────────────────────
CORS_ALLOW_ALL_ORIGINS = True
CORS_ALLOW_CREDENTIALS = True
CORS_ALLOW_HEADERS = [
    "authorization",
    "content-type",
    "x-csrf-token",
    "accept",
    "origin",
    "x-requested-with",
]

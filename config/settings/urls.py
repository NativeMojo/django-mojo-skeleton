from django.urls import path, include
from django.conf import settings as django_settings
from django.conf.urls.static import static

from mojo.helpers import error_pages
from mojo.helpers.settings import settings
from mojo.rest.openapi import openapi_schema_view

MOJO_PREFIX = "/".join([settings.get("MOJO_PREFIX", "api/").rstrip("/"), ""])
ALLOW_ADMIN_SITE = settings.get("ALLOW_ADMIN_SITE", False)

urlpatterns = [
    # Nothing is published at "/" yet. Serves the framework's unconfigured-root
    # page to a browser and a healthy JSON 200 to a monitor. Replace this route
    # as soon as the project actually serves something at its root address.
    path("", error_pages.render_root_page),
    path("", include('mojo.urls')),
]

if ALLOW_ADMIN_SITE:
    from django.contrib import admin
    admin_prefix = settings.get("ADMIN_SITE_PREFIX", "nope")
    urlpatterns.append(path(f'{admin_prefix}/', admin.site.urls))

if settings.OPENAPI_DOCS_SHOW:
    urlpatterns.append(path('docs/schema', openapi_schema_view))

# Local/dev convenience: serve MEDIA_URL from MEDIA_ROOT when explicitly enabled.
if getattr(django_settings, "SERVE_LOCAL_MEDIA", False):
    urlpatterns += static(django_settings.MEDIA_URL, document_root=django_settings.MEDIA_ROOT)


# Django's own error handlers. Each keeps the exact JSON an API client got
# before, and serves the styled page only to a caller that asked for text/html
# specifically — see docs/django_developer/core/error_pages.md.
# Note: Django routes to these only when DEBUG is False.

def handler400(request, exception=None):
    return error_pages.error_response(
        request, {"error": "Bad request", "code": 400, "status": False}, 400)


def handler403(request, exception=None):
    return error_pages.error_response(
        request, {"error": "Permission denied", "code": 403, "status": False}, 403)


def handler404(request, exception=None):
    return error_pages.error_response(
        request, {"error": "Endpoint not found", "code": 404, "status": False}, 404)


def handler500(request):
    return error_pages.error_response(
        request, {"error": "system error", "code": 500, "status": False}, 500)

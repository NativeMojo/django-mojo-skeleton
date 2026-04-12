from mojo.helpers.response import JsonResponse, HttpResponse
from django.urls import path, include
from django.conf import settings as django_settings
from django.conf.urls.static import static

from mojo.helpers.settings import settings
from mojo.rest.openapi import openapi_schema_view

MOJO_PREFIX = "/".join([settings.get("MOJO_PREFIX", "api/").rstrip("/"), ""])
ALLOW_ADMIN_SITE = settings.get("ALLOW_ADMIN_SITE", False)

urlpatterns = [
    path("", lambda request: HttpResponse("<html><body><h1>Permission Denied</h1></body></html>", content_type="text/html")),
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

def handler404(request, exception):
    return JsonResponse({"error": "Endpoint not found", "code": 404, "status": False}, status=404)

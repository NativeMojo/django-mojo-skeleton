from django.core.exceptions import ImproperlyConfigured

import mojo.decorators as md
from mojo.helpers.settings import settings

from system.services import broadcast_update

SYSTEM_UPDATE_TOKEN = settings.SYSTEM_UPDATE_TOKEN
if not SYSTEM_UPDATE_TOKEN:
    raise ImproperlyConfigured(
        "SYSTEM_UPDATE_TOKEN must be set in var/django.conf to enable apps/system's update trigger"
    )


@md.POST("update")
@md.requires_bearer(SYSTEM_UPDATE_TOKEN)
def on_system_update(request):
    broadcast_update.trigger()
    return {"triggered": True}

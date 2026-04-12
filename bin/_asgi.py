import os
import paths

paths.load_apps()
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')

from mojo.apps.realtime.routing import create_application
application = create_application()  # Done!

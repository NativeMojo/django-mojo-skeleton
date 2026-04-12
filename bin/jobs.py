#!/usr/bin/env python

import paths
import os
import sys
# Import logging and helper modules
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')

paths.load_apps()
from mojo.helpers import paths as jpaths

jpaths.configure_paths(__file__, 0)

from mojo.apps.jobs import cli

if __name__ == "__main__":
    if "start" == sys.argv[1]:
        if cli.is_engine_running() and cli.is_scheduler_running():
            if "-v" in sys.argv:
                print("engine and scheduler are already running")
            sys.exit(0)

    import django
    django.setup()

    cli.main()

#!/usr/bin/env python

import paths
import os
# Import logging and helper modules
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')

paths.load_apps()
from mojo.helpers import paths as jpaths

jpaths.configure_paths(__file__, 0)
from mojo.apps.tasks import runner

if __name__ == "__main__":
    runner.main()

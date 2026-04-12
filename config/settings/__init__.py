from mojo.helpers import paths, modules, settings
from . import version

VERSION = version.__version__
# configure from the current folder and go 1 folder back
paths.configure_paths(__file__, 1)
# build djangos INSTALLED_APPS
paths.configure_apps()
# load the paths into globals
modules.load_module_to_globals(paths, globals())

# this expects a project_path/var/profile file containing a profile name to load
settings.load_settings_profile(globals())
# this loads project_path/var/django.conf and overrides any settings vars
settings.load_settings_config(globals())

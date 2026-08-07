"""
Project Path Configuration Script

This script dynamically sets up the project's directory structure and ensures all necessary paths
are correctly added to `sys.path`. It is used to:
- Define key project paths (e.g., ROOT, VAR_PATH, DJANGO_ROOT).
- Dynamically load additional modules from `.site_packages`.
- Automatically include app directories from the `apps/` folder.
- Configure Python's import path (`sys.path`) to recognize these locations.

This ensures that all project modules and dependencies are properly recognized
without hardcoding absolute paths.
"""
import sys
from pathlib import Path
import secrets
import string

# Resolve paths
FILE = Path(__file__).resolve()
ROOT = FILE.parent.parent
PROJECT_NAME = ROOT.name.upper()

# Define key paths
PROJECT_ROOT = ROOT
VAR_ROOT = PROJECT_ROOT / "var"
BIN_ROOT = PROJECT_ROOT / "bin"
APPS_ROOT = PROJECT_ROOT / "apps"
CONFIG_ROOT = PROJECT_ROOT / "config"
APPS_CONFIG_FILE = APPS_ROOT / "apps.json"
LOG_ROOT = VAR_ROOT / "logs"

EXTRA_MODULES = ROOT / "packages"
VERSION_FILE = CONFIG_ROOT / "version.py"

# Add key directories to sys.path
sys.path.insert(0, str(EXTRA_MODULES))
sys.path.insert(0, str(CONFIG_ROOT))

# Load additional site-packages paths from .site_packages file
SITE_PACKAGES_FILE = ROOT / ".local_packages"

if SITE_PACKAGES_FILE.exists():
    with SITE_PACKAGES_FILE.open("r") as f:
        site_packages_paths = [path.strip() for path in f.readlines() if path.strip()]
    for path in site_packages_paths:
        site_path = Path(path)
        if site_path.exists():
            if str(site_path) in sys.path:
                sys.path.remove(str(site_path))
            sys.path.insert(0, str(site_path))

# Load app directories dynamically
APP_FOLDERS = []

def generate_secret_key(length=50):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for i in range(length))

def check_var():
    if not VAR_ROOT.exists():
        create = input(f"VAR_ROOT directory {VAR_ROOT} doesn't exist. Create it? [y/N] ")
        if create.lower() == 'y':
            # Create var directory
            VAR_ROOT.mkdir(parents=True)

            # Create and write to profile file
            profile_path = VAR_ROOT / "profile"
            while True:
                profile_type = input("Select profile type (local/test/prod): ").lower()
                if profile_type in ['local', 'test', 'prod']:
                    profile_path.write_text(profile_type)
                    break
                print("Invalid profile type. Please choose 'local', 'test', or 'prod'")

            # Create django.conf with secret key
            django_conf = VAR_ROOT / "django.conf"
            secret_key = generate_secret_key()
            docs_key = ''.join(secrets.choice(string.ascii_uppercase) for _ in range(4)) + '-' + \
                       ''.join(secrets.choice(string.ascii_lowercase) for _ in range(4))
            assignments = [
                f"SECRET_KEY = '{secret_key}'",
                "ALLOW_ADMIN_SITE = False",
                "ADMIN_SITE_PREFIX = 'admin'",
                "OPENAPI_DOCS_SHOW = False",
                f"OPENAPI_DOCS_KEY = '{docs_key}'",
            ]
            django_conf.write_text("\n".join(assignments) + "\n")
            # Create logs directory
            log_dir = VAR_ROOT / "logs"
            log_dir.mkdir(exist_ok=True)
            # Create keys directory
            key_dir = VAR_ROOT / "keys"
            key_dir.mkdir(exist_ok=True)
            print(f"Created VAR_ROOT at {VAR_ROOT}")
        else:
            print("Skipping VAR_ROOT creation")

def load_apps(include_tests=False):
    if APPS_ROOT.exists():
        for item in APPS_ROOT.iterdir():
            if item.is_dir() and str(item) not in sys.path:
                if include_tests or not item.name.endswith("tests"):
                    APP_FOLDERS.append(str(item))
                    sys.path.append(str(item))
    return APP_FOLDERS

def init_django():
    import django
    import os
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')
    load_apps()
    django.setup()

#!/usr/bin/env python
import os
import sys
from django.core.management import execute_from_command_line
from django.urls import get_resolver, URLPattern, URLResolver
import paths

def sync_schema(args):
    # Run makemigrations
    execute_from_command_line(['manage.py', 'makemigrations'] + args)
    # Run migrate
    execute_from_command_line(['manage.py', 'migrate'] + args)

def show_urls():
    import django
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "settings")
    django.setup()
    resolver = get_resolver()
    print("\nSHOWING ROUTES:\n")
    list_urls(resolver.url_patterns)
    print()

def list_urls(urlpatterns, prefix=''):
    for pattern in urlpatterns:
        if isinstance(pattern, URLPattern):
            print(f" -> {prefix}{pattern.pattern}")
        elif isinstance(pattern, URLResolver):
            list_urls(pattern.url_patterns, prefix + str(pattern.pattern))
            print('')

def main():
    paths.load_apps()
    paths.check_var()
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')
    try:
        if len(sys.argv) > 1 and sys.argv[1] in ['sync_schema', 'sync_db']:
            # Pass any additional arguments after 'sync_schema'
            sync_schema(sys.argv[2:])
        elif len(sys.argv) > 1 and sys.argv[1] in ['routes', 'show_urls']:
            show_urls()
        else:
            execute_from_command_line(sys.argv)
    except Exception as exc:
        raise RuntimeError("Management command execution failed") from exc

if __name__ == '__main__':
    main()

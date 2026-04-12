# Documentation Rules

## Two Doc Tracks

| Track | Path | Audience |
|-------|------|----------|
| Django Developer | `docs/django_developer/` | Backend devs, AI agents |
| Web Developer | `docs/web_developer/` | API consumers, frontend devs |

Both must be updated when behavior changes.

## Structure

Each app has a folder with a `README.md` index linking to bite-sized topic files. No monolithic docs — split by topic.

## When to Update

- New endpoints or changed API contracts → both tracks
- New models or changed data structures → django_developer track
- Config changes → both tracks
- Update `CHANGELOG.md` for meaningful behavior or API changes

## Framework Docs

django-mojo docs are the source of truth. Link, don't copy:
- Django Developer: `https://github.com/NativeMojo/django-mojo/raw/refs/heads/main/docs/django_developer/README.md`
- Web Developer: `https://github.com/NativeMojo/django-mojo/raw/refs/heads/main/docs/web_developer/README.md`

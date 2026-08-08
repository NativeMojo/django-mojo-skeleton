# Django-Mojo Skeleton Agent Guide

This file is loaded automatically by ChatGPT and Codex. Read `CLAUDE.md` in
full at the start of every task; it remains the detailed shared project
handbook.

Use the Maestro board configured in `.claude/maestro.json` and select the
smallest matching generated skill under `.agents/skills/`: `$maestro-task`,
`$maestro-scope`, `$maestro-build`, `$maestro-auto`, `$maestro-vibe`,
`$maestro-release-note`, or `$sites-verify`. If Maestro is unavailable, say so
explicitly instead of silently changing workflows.

The files under `.claude/rules/` are provider-neutral. Read the applicable
rules before editing. Follow the NativeMojo workspace's isolated-worktree,
explicit-pathspec commit, cleanup, and no-push requirements. Preserve this
repo's purpose as a reusable project skeleton: do not commit machine-local
configuration, generated secrets, or application-specific state. For
Codex-authored commits use
`Co-Authored-By: OpenAI Codex <noreply@openai.com>`.

## Skill Synchronization

The upstream-managed dev skill pack lives under `.claude/skills/`. ChatGPT and
Codex discover generated counterparts under `.agents/skills/`; never hand-edit
those generated files. After `get_dev_skills()` refreshes the upstream pack,
run:

```bash
scripts/sync_maestro_skills.py
scripts/sync_maestro_skills.py --check
```

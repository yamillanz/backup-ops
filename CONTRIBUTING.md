# Contributing to Backup-Ops

Backup-Ops is open source and welcomes contributions — especially new source
catalog entries, browser/platform roots, and better SELF-HEAL diagnoses.

## Ground rules

- **No personal data in the repo.** `config/user.yml`, `data/*`, and anything tied to
  one person's machine stay gitignored. All committed sample configs are generic.
- **The catalog is data, not code.** New back-uppable things go into
  `config/manifest.yml` as a `source` (id, label, kind, enabled, dest, platforms,
  include/exclude). Don't hardcode paths in the bash scripts.
- **Cross-platform by default.** When adding a browser or folder, supply roots for
  `linux`, `windows`, `macos` and (when meaningful) `wsl`.
- **Agent docs stay in sync.** If you change the engine, update the relevant
  `modes/*.md` and/or `AGENTS.md` so agents loading the skill behave correctly.

## Development loop

```bash
bash -n scripts/*.sh                       # syntax
bash -c 'source scripts/lib.sh && render_catalog linux'
bash scripts/probe.sh                      # detection sanity
# full rehearsal in staging:
export HOME_BASE=/tmp/backup-ops-drill/home
bash scripts/backup.sh --root /tmp/backup-ops-drill/backup-dst --no-mount-check
bash scripts/verify.sh --tree /tmp/backup-ops-drill/backup-dst
bash scripts/restore.sh --from /tmp/backup-ops-drill/backup-dst --to /tmp/backup-ops-drill/new-home
bash scripts/verify.sh --tree /tmp/backup-ops-drill/new-home --restored
```

(That sequence is exactly what `modes/drill.md` documents — run it in an agent CLI
as `/backup-ops drill`.)

## Pull requests

- Small, focused changes; one logical unit per PR.
- Add or update tests: for engine changes, a `drill`-style rehearsal is the test.
- For catalog additions, list the new source and confirm `render_catalog` output.
- Update `README.md` if user-facing behavior changed.

## Issues

- Bug reports: include the command run, the exact error, and the catalog/user.yml
  (redact any secrets).
- Feature requests: describe what you want to back up / where / on which OS. New
  sources or platforms are the fastest way to extend value.

By contributing you agree your changes are licensed under the same MIT license as
the project.
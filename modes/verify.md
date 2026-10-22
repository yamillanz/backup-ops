# verify mode

Goal: prove the backup (or a restored tree) is honest, complete, and policy-correct.

## Backup-tree checks

```bash
bash scripts/verify.sh --tree <root>
```

The backup's own `migration.yml`/`backup-info.yml` selection is authoritative; a
legacy backup falls back to this host's active selection with a warning.

Checks:
- selected source dirs non-empty; tars exist/readable and `sha256sum -c` matches
- drained DBs + browser mirrors: `PRAGMA integrity_check`
- `manifest.sha256` covers every file; mismatch fails
- `migration.yml` has source_family + selection; copied catalog hash matches
- `backup-info.yml` critical_gaps = 0
- `coverage-report.md` has no `CRITICAL GAPS`
- native package inventory non-empty (unless the source had no supported manager)
- AppImage copies executable + sha256
- NetworkManager files 600; SSH host keys 600
- VM/network XML well-formed; compose YAML parses when PyYAML exists
- no cache/trash payload in the pack
- `system_files/manifest.tsv` present; warn if sudo prevented all copies

## Restored checks

```bash
bash scripts/verify.sh --tree <new-home> --restored
```

- dotfiles parse (`zsh -n`/`bash -n`)
- SSH keys 600; keyring dir 700
- restored browser DB integrity
- fonts present when `fonts_user` was applied
- `desktop_env` **not** applied when source/target desktops differ; staged copy exists
- `migration-report.md` and package plan present
- `restore-info.yml` has no `failed` commands
- only sources recorded as applied are reported as restored (staged sources are
  shown as staged, never as restored)

## Behavior

1. Run the script; read per-section output (✅/⚠️/❌).
2. Any ❌ → `heal` for that section, retry once, re-verify. Only `passed` closes it.
3. Warnings are not failures but must be surfaced: missing legacy manifest, keyring
   not selected, sudo-denied `/etc` copies, PyYAML unavailable, partial audit.
4. Summarize in a table in `language.output`.
5. Append to `data/run-log.md`; update `data/state.yml`; `data/last-run.json` is
   written by the script.

## Escalation

Repeated failure on browser DBs, secrets, package inventory, or checksums → escalate
with options (A/B), record the blocker, never report false PASS. Do not weaken a
check to make a run pass.

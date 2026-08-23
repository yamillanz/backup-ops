# verify mode

Goal: prove the backup (or a restored tree) is honest, runnable, and complete.

## What it checks

`bash scripts/verify.sh --tree <root> [--restored]` evaluates, per section:
- **structure** (backup-tree): each section dir exists and is non-empty (a section
  may be a `.tar.gz` file at its dest path instead of a folder).
- **tars**: readable (`tar -tzf`), `sha256sum -c` matches recorded hash.
- **sqlite**: every drained browser DB opens, `PRAGMA integrity_check` == ok; report
  each DB path with ✅/❌.
- **restored-side**: dotfiles parse (`zsh -n`, `bash -n`), SSH key perms 600, and
  catalog roots that now exist on disk.

## Behavior

1. Run the script. Read per-section output.
2. Any ❌ → `heal` for that section, retry, re-verify. Only `passed` closes it.
3. Summarize in a table in `language.output` (default `en`):

```
Backup verification — <date>
  dirs:              ✅ Documents/Projects/... (1,204 files)
  browsers:          ✅ Firefox, Brave, Chrome, ... (sqlite integrity ok)
  configs+dofiles:   ✅ tar(s) readable, sha256 OK
  secrets:           ✅ ssh+gnupg tar OK (perms verified on restore)
  system-state:      ✅ snapshot captured
Overall: PASS
```

4. Append to `data/run-log.md`; update `data/state.yml`; write `data/last-run.json`.

## Escalation

Repeated failure on a browser DB or secrets → SELF-HEAL escalate with options (A/B),
record the blocker, and never report false PASS.
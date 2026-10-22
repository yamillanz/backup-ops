# heal mode

Goal: resolve a specific backup/restore/verify failure using the agent's reasoning —
the concrete implementation of the SELF-HEAL protocol in AGENTS.md. Auto-invoked
when a step fails; also available on request.

## Trigger
- User says "fix/heal/there was an error/resolve this" → read `data/state.yml` for
  the failing section(s).
- backup/restore/verify aborted/failed → heal reads `state`/`run-log` for context.

## Procedure (one full round, then escalate)

For each failing item:

### 1. Diagnose
Read the exact error + exit code + the last 20 log lines. Classify against the known
classes (from AGENTS.md SELF-HEAL):

| Symptom | Likely cause | First fix (safe) |
|---------|-------------|------------------|
| "No space left on device" | target full | `df -h <dest>`; prune excluded junk already mirrored; shrink scope; suggest drive |
| "failed to set permissions/times" | FAT32/exFAT/ntfs USB | re-run `--no-perms --chmod=ugo=rwX` (or drop `-t`); store perms in tar |
| sqlite locked / WAL | live DB | `sqlite3 db "PRAGMA wal_checkpoint(TRUNCATE);"` then `.backup` |
| sqlite integrity != ok | torn copy | re-drain via `.backup`; if still bad it's corrupt AT SOURCE — copy as-is, flag loudly |
| "file changed as we read it" | app writing during copy | retry once; snapshot via `.backup`; escalate |
| permission denied (source) | unreadable dir | list it; ask skip-with-sudo or exclude |
| hardlink failed / 2device | cross-FS incremental | drop `--link-dest` for that run |
| source missing | dir gone | log `skipped-missing`, continue (never fail run) |
| browser "profile can't be loaded" | version mismatch | restore data files only; let app rebuild Local State/Prefs |
| Chromium passwords won't decrypt | keyring missing/mismatch | restore `~/.local/share/keyrings` before the profile, or use browser sync; never break the wallet |
| package name not found on target | cross-family rename | do not guess; flag it in the package plan and ask for the target name |
| desktop configs cause breakage | DE mismatch/version drift | revert to `safe`; restore `desktop_env` only on same DE/version with `same-de` |
| `/etc`/NetworkManager skipped | sudo not available | leave `skipped-permission`; give the exact manual command; never fail the whole run |
| VM disk copy fails | VM running / permission | power off; retry with `sudo -n rsync --sparse`; definitions are still safe |
| Docker volume path absent | rootless/custom data-root | use `containers/backup-volumes.sh` helper-container export; do not assume `/var/lib/docker` |
| AppImage not executable | mode lost on medium | `chmod +x` the copy; verify sha256 against `appimages.tsv` |
| `CRITICAL GAPS` in coverage | browser/package/secret missing | fix the source or explicitly record a user-approved deviation; do not call it PASS |

### 2. Fix + retry
Apply the first fix, re-run the same step from `backup.md`/`restore.md`, re-verify.
One retry only (`safety.max_section_retries`).

### 3. Re-verify
`bash scripts/verify.sh --tree <target> [--restored]` for the affected section. Only
a clean PASS closes the issue.

### 4. Escalate (options in `language.output`, default `en`)
Present 2–3 concrete options; record the blocker under `data/state.yml → issues`:
```
Option A: skip <section> (data stays in the backup, untouched)
Option B: restore to a neutral profile and re-import data files
Option C: raw rsync of <item> regardless (may produce torn file)
```
Never silently drop a failure. A failed secrets/browser item keeps the run `failed`.

## Record
`data/run-log.md` + `data/state.yml` issue block: item, diagnosis, fix, result
(resolved / escalated / user-decision).
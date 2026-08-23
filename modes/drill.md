# drill mode

Goal: rehearse a full backup→restore→verify round trip against **staging folders**
(never the real home, never the real destination) so both the engine and the user's
expectations are validated before the real migration. Zero risk.

## When to use
- Before first real backup / restore ("practice first").
- After editing the catalog or scripts (regression test).

## Procedure

1. Build a **pretend home**:
   ```
   mkdir -p /tmp/backup-ops-drill/home/{Documents,Projects,.config,.ssh,.gnupg,.mozilla/firefox/profile}
   ```
   add small real files, a `sqlite3` DB, a dotfile, a dummy SSH key pair — so dir/
   drain/tar paths all exercise.

2. Point the engine at staging, WITHOUT editing committed config:
   ```
   export HOME_BASE=/tmp/backup-ops-drill/home     # ~ resolves here (lib.sh)
   bash scripts/backup.sh --root /tmp/backup-ops-drill/backup-dst --no-mount-check
   ```
   `--root` overrides destination; `--no-mount-check` bypasses the external-drive
   guard (drills only).

3. Verify the backup tree → must PASS.
4. Restore to a *third* staging home:
   ```
   bash scripts/restore.sh --from /tmp/backup-ops-drill/backup-dst \
     --to /tmp/backup-ops-drill/new-home
   ```
5. Verify restored side (`--restored`) → must PASS.
6. Report the drill matrix (backup→verify→restore→verify, each ✅/❌) in
   `language.output`. Any ❌ → `heal` before the real run.

## Cleanup
Offer to remove `/tmp/backup-ops-drill` (never auto-delete without confirmation).
Append drill result to `data/run-log.md`; update `data/state.yml` (`last_drill`).
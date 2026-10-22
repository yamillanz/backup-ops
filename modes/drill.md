# drill mode

Goal: rehearse a full backup→verify→restore→verify round trip against **staging
folders** (never the real home, never the real destination) so both the engine and the
user's expectations are validated before the real migration. Zero risk.

## When to use
- Before the first real backup/restore ("practice first").
- After editing the catalog or scripts (regression test).
- Before a cross-family migration, to see the migration report and DE gate.

## Procedure

1. Build a **pretend home** with every kind of source:
   ```bash
   mkdir -p /tmp/backup-ops-drill/home/{Documents,Projects,.config/app,.config/dconf,.ssh,.gnupg,.local/share/fonts,.local/share/themes/Test,.local/bin,.mozilla/firefox/test.default,Apps}
   printf 'doc\n' > /tmp/backup-ops-drill/home/Documents/doc.txt
   printf 'export ZDOTDIR=$HOME\n' > /tmp/backup-ops-drill/home/.zshrc
   printf 'key\n' > /tmp/backup-ops-drill/home/.ssh/id_test
   chmod 600 /tmp/backup-ops-drill/home/.ssh/id_test
   sqlite3 /tmp/backup-ops-drill/home/.mozilla/firefox/test.default/places.sqlite \
     'create table moz_places(id integer);'
   printf 'fake\n' > /tmp/backup-ops-drill/home/Apps/Test.AppImage
   chmod 755 /tmp/backup-ops-drill/home/Apps/Test.AppImage
   ```

2. Back up with staging:
   ```bash
   HOME=/tmp/backup-ops-drill/home \
   bash scripts/backup.sh --root /tmp/backup-ops-drill/backup-dst \
     --no-mount-check --force \
     --include packages,documents,dotfiles,secrets,configs,desktop_env,browsers,fonts_user,themes,appimages,system_files,network
   ```
   `--root` overrides destination; `--no-mount-check --force` are for drills only.
   The fake home keeps `system_files`/`network` reads on the real host; that is
   expected for a drill that exercises the collectors.

3. Verify the backup tree → must PASS:
   ```bash
   bash scripts/verify.sh --tree /tmp/backup-ops-drill/backup-dst
   ```

4. Plan the restore (no target writes):
   ```bash
   bash scripts/restore.sh --from /tmp/backup-ops-drill/backup-dst \
     --to /tmp/backup-ops-drill/new-home --plan-only
   ```
   Read `data/migration-report.md`. Confirm `desktop_env` is staged under `safe`.

5. Restore to the staging home:
   ```bash
   mkdir -p /tmp/backup-ops-drill/new-home/.mozilla/firefox
   bash scripts/restore.sh --from /tmp/backup-ops-drill/backup-dst \
     --to /tmp/backup-ops-drill/new-home
   ```
   (Create the browser root only if you want the browser profile path exercised;
   otherwise restore correctly skips it with "install the browser first".)

6. Verify restored side → must PASS:
   ```bash
   bash scripts/verify.sh --tree /tmp/backup-ops-drill/new-home --restored
   ```

7. Optional gate tests:
   - Copy the backup, edit `migration.yml` source/target desktops to differ, run
     `--plan-only`; confirm `desktop_env` is staged and risk is high.
   - Remove `migration.yml`, run `--plan-only`; confirm the legacy warning and that
     no target files are written.

8. Report the drill matrix (backup→verify→plan→restore→verify) in `language.output`.
   Any failure → `heal` before the real run.

## Cleanup
Offer to remove `/tmp/backup-ops-drill`; never auto-delete without confirmation.
Append the result to `data/run-log.md`; update `data/state.yml` (`last_drill`).

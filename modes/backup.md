# backup mode

Goal: copy the active selection (catalog + `config/user.yml`) to the destination,
audit coverage, and verify — with SELF-HEAL. The conversational setup lives in
`start`; this is the "run it" step.

## Preflight

1. Load `config/manifest.yml`, `config/user.yml`, `data/state.yml`.
2. Resolve the migration profile (`migration:` block) and echo source/target.
3. Confirm destination mounted and writable. `backup.sh` refuses same-disk as `/`
   unless `--force`; it estimates selected payload + 10% and checks free space.
4. Resolve selection: `selection` > `preset` > `default_preset`.
5. Preview: `bash scripts/backup.sh --dry-run`.

## Sequence (engine-driven)

Run `bash scripts/backup.sh` (flags: `--preset`, `--include`, `--exclude`, `--ask`,
`--root`, `--no-mount-check`, `--force`).

1. **dir** — rsync mirror of trees. Candidate roots (`native > flatpak`) resolve to
   the first existing one; alternates are logged, not copied. Excludes apply.
2. **tar** — dotfiles, app configs, desktop-env state, histories, secrets, local
   share. Includes/excludes come from the catalog. Secrets tar is permission-tight.
3. **drain** — browser history/places/cookies via `sqlite3 .backup` +
   `PRAGMA integrity_check`, then rsync the profile.
4. **snapshot** — generated collectors:
   - `packages`: native explicit/full, AUR, Flatpak, Snap, install hints
   - `snapshots`: OS/DE versions, fstab, mounts, cron, systemd units/timers
   - `system_files`: selected `/etc` files, manual restore
   - `network`: NetworkManager profiles, VPN/WiFi state, 600, manual restore
   - `virtualization`: libvirt XML/network XML, VirtualBox inventory, disk sizes;
     disks only when `migration.include_vm_disks: true`
   - `containers`: Docker/Podman inventory + compose copies + volume-backup script
   - `appimages`: scan/copy `*.AppImage`, preserve exec bit + sha256
   - `gaming_saves`: Ludusavi if present; otherwise detected roots + instructions
   - `audit`: user-owned files outside `$HOME` (report only)

## After the copy

The engine writes and checks:

- `migration.yml` — source/target profile, selection, catalog hash
- `backup-info.yml` — host, platform, selection, critical-gap count
- `coverage-report.md` — detected vs packed; `CRITICAL GAPS` fails the run
- `manifest.sha256` — every file in the backup
- `preflight.txt` — free space + cache/trash sizes

Non-destructive: no `--delete`; no package installs; no `/etc` writes; no VM disks
unless explicitly requested and VMs are off. FAT32/exFAT targets auto-decline perms.

## Verification gate

```bash
bash scripts/verify.sh --tree <destination>
```

PASS required. It checks the backup's own selection, tars + checksums, sqlite,
package inventory, AppImage mode/hash, network permissions, VM XML, compose YAML,
cache/trash absence, migration manifest, catalog hash, and critical gaps. Fail →
`heal`, retry once, escalate.

## Record

`data/run-log.md`; `verify` writes `data/last-run.json`. Update `data/state.yml`
per section (`done` / `failed` / `skipped-missing`).

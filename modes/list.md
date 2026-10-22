# list mode

Goal: show exactly what backup-ops *would* back up or restore, cheaply and with zero
writes. Read-only preview.

## Behavior

1. Load catalog + `config/user.yml`.
2. Print the effective selection, grouped, with root, `restore_policy`, and
   `restore_phase`:
   ```bash
   bash -c 'source scripts/lib.sh; for id in $(active_source_ids); do
     echo "$id|$(catalog_field "$id" kind)|$(catalog_field "$id" root)|$(source_policy "$id")|$(source_phase "$id")";
   done'
   ```
3. Print the migration profile:
   ```bash
   bash scripts/probe.sh | sed -n "1,25p"
   ```
   Source distro/family/desktop, package manager, Flatpak, gaming, VMs, containers,
   keyring, and drives.
4. Optionally run `bash scripts/backup.sh --dry-run` to show actual rsync deltas —
   ask first; can be slow on large trees.
5. Highlight risks:
   - destination missing/not mounted
   - sources present but not selected (especially browsers/secrets)
   - family/desktop change with `restore_profile: safe`
   - huge sources (Downloads, Games, flatpak_data, VM disks)
   - manual-only sources (`system_files`, `network`, `virtualization`, `containers`)
6. Do not modify config.

## Record

Read-only; may append one `data/run-log.md` line (`list: displayed scope`).

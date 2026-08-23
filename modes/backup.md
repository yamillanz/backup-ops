# backup mode

Goal: copy the user's active selection (config/user.yml → catalog) to the
destination and verify — with SELF-HEAL. This mode is the "run it" step; the
conversational setup lives in `start`.

## Preflight

1. Load `config/manifest.yml` (catalog) + `config/user.yml` (selection/destination)
   + `data/state.yml`.
2. Confirm destination mounted + free space (`safety.free_space_min_gb`). If absent:
   run `probe` and offer drives; use `start` to set it. The engine refuses to write
   to the same-disk as `/`.
3. Resolve the effective selection:
   - `user.yml selection:` (explicit ids) wins,
   - else `user.yml preset:` (essentials/full/minimal) → catalog `presets.` list,
   - else catalog `default_preset`.
4. Preview: `bash scripts/backup.sh --dry-run` before the real run.

## Sequence (engine-driven, no hardcoded paths)

Run `bash scripts/backup.sh` (flags: `--preset`, `--include`, `--exclude`, `--ask`).
The engine reads the catalog and dispatches per source kind:

1. **dir** — rsync mirror of whole trees (Documents, Projects, Desktop, Pictures,
   Videos, Music, Public, Downloads, Games, AppImages, Calibre). CATALOG excludes
   from the `global-excludes.txt` + any per-source `exclude:`.
2. **browsers (drain)** — for each browser present on this platform (from catalog
   `browsers:` per-platform roots): WAL-safe `sqlite3 .backup` for History/places/
   Cookies (verify `PRAGMA integrity_check`), then rsync the full profile. Warn if
   the browser is running; never kill it without asking.
3. **tar** — configs, dotfiles, histories, secrets → `.tar.gz` + sha256. Secrets tar
   is `0600`.
4. **snapshot** — system state → `system-state/snapshot.txt` (packages, flatpaks,
   fstab, systemd units, toolchain sizes).

Non-destructive: `--delete` only with explicit per-run approval. FAT32/exFAT targets
auto-decline perms (`--no-perms --chmod=ugo=rwX`) per SELF-HEAL.

## Verification gate

`bash scripts/verify.sh --tree <destination>` — PASS per section is required.
Fail → `heal`, retry once, then escalate with options. Run NOT done until PASS (or a
documented user-approved deviation, recorded in `data/state.yml`).

## Record

`data/run-log.md` + `data/state.yml` (per-section: done/failed/skipped-missing +
resumable flags). Write `data/last-run.json` via verify.

## Output language

Follow `language.output` from `config/user.yml` (default `en`).
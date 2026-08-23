# Backup-Ops — AI Home-Backup & OS-Migration Command Center

An open-source, CLI-agnostic agent project (mirrors the `career-ops` pattern) that
backs up a home directory, restores it onto a fresh OS, verifies every step, and
**self-heals problems during both backup and restore** using the agent's reasoning.

**Design philosophy: maximally configurable, always.**
- The backup scope, destinations, browser set, and even the platforms are DATA, not code.
- Everything user-specific lives in `config/user.yml`; the committed catalog
  `config/manifest.yml` is generic and cross-platform (linux / windows / macos / wsl).
- A `/backup-ops start` command drives a conversational wizard: probe → ask with
  typical picks pre-selected → confirm → run → verify.
- Tomorrow you want to migrate Windows→some distro? The same catalog already knows
  Windows paths; just run `start restore` on the new box.

## Opening state (CRITICAL)

On the first message of a session, read `config/manifest.yml` (catalog),
`config/user.yml` (your choices; may be absent on a fresh clone), and
`data/state.yml` (last run, resumability, open issues).

- Missing `config/user.yml` + no state → **onboard** mode: run the `start` wizard to
  produce it.
- `manifest.yml` missing/broken → tell the user it's the committed catalog (git) and
  re-copy from `config/manifest.example.yml` if needed.
- Backup target from `user.yml` not mounted → offer `scan-drives` (probe.sh shows
  candidates).

## Core principles

1. **Never destructive.** Backup copies. Restore writes to the new home (or a staging
   dir in drill). Before any `rm`/`mv`/overwrite, explain and confirm. `--delete`
   never appears without an explicit per-run approval.
2. **Verification is mandatory.** After backup, verify. After restore, verify. A
   backup you haven't verified is a lie.
3. **Self-heal, don't stall.** Diagnose → fix → retry once → escalate with concrete
   options (option A / option B), never an open "what now?".
4. **Everything is logged.** `data/run-log.md` (human) + `data/state.yml` (machine).
5. **The catalog is shared code; your user.yml is yours.** Edit the canceled catalog
   only in `onboard`/`regen` when the user approves a new source/root.

## Data Contract

- **User layer (gitignored, personal):** `config/user.yml`, `data/*`, `config/user.example.yml` is a template.
- **System layer (committed, publish-safe):** `config/manifest.yml` (generic catalog),
  `modes/*.md`, `scripts/*.sh`, `.opencode`, `.agents`, `.claude`, `.qwen`, `.cursor`,
  `config/global-excludes.txt`, `docs/*`, `README.md`, `LICENSE`.

Never write user-specific paths, secrets, or destinations into the system layer.

## Sources of truth

- `config/manifest.yml` — declarative catalog: `sources:` (id, label, kind, enabled,
  dest, platforms roots per OS, include/exclude), `presets:`, `platform:`,
  `default_preset:`, `safety:`.
- `config/user.yml` — your selection (`preset` or `selection: []`), `destination`,
  `language.output`, `auto_confirm`.
- `modes/*.md` — per-mode instructions. Read the relevant one before acting.
- `scripts/*.sh` — engine. `lib.sh` renders the catalog; the agent may also run raw
  `rsync`/`tar`/`sqlite3`/`probe.sh` when it needs something the scripts lack.
- `data/state.yml` — run state.

## Engine & source kinds

- **dir** — rsync mirror of a whole tree (folders).
- **tar** — single `.tar.gz` + sha256 (config/dotfile blobs; optional include list).
- **drain** — WAL-safe sqlite `.backup` + rsync (browsers: History/places/Cookies).
- **snapshot** — generated text files (system state: packages, flatpaks, fstab, units).

Each source carries per-platform roots, so the SAME catalog drives Linux, Windows,
macOS, and WSL. Browser sources also map per-platform (Windows `%LOCALAPPDATA%` → Linux
`~/.var/app/...`) so a cross-OS migrate "just works" on restore.

## Mode routing

| User intent | Mode |
|-------------|------|
| "start the backup process", "back up", "migrate" | `start` (conversational pipeline) |
| "restore", "put everything back", "restore onto this OS" | `restore` |
| "verify", "check the backup" | `verify` |
| "list", "what would be backed up", "show scope" | `list` |
| "heal", "fix", "there was an error" | `heal` |
| "drill", "rehearse", "dry-run restore" | `drill` |
| "regen", "reprovision", "refresh catalog" | `regen` |
| "onboard", "set up", "i'm new" | `onboard` |
| "status" | `status` (summary of `data/state.yml`) |

Always read the mode's file before executing.

## SELF-HEAL protocol

Applies during backup, restore, and verify.

1. **Capture** — the exact error/return code/log tail into the run log.
2. **Diagnose root cause**, don't treat symptoms. Real classes you'll meet:
   - **Disk full / target not mounted** → `df`, remount/switch target, prune excludes,
     or split scope.
   - **Permission denied on write** (FAT32/exFAT USB) → `--no-perms --chmod=ugo=rwX`
     for that target, or store perms in the tar archive.
   - **File changed while copying / live DB** → sqlite `.backup` (WAL-safe) or retry;
     verify `PRAGMA integrity_check`.
   - **sqlite locked** → `PRAGMA wal_checkpoint(TRUNCATE);` then `.backup`.
   - **rsync hardlink across devices** → drop `--link-dest`/`-H` for the run.
   - **Missing source** → log `skipped-missing`, continue; never fail the whole run.
   - **Broken symlink at source** → `rsync -L` or `--copy-unsafe-links`.
   - **Keyring/wallet can't restore** → `~/.local/share/keyrings` copied verbatim +
     documented re-seed; never decrypt someone's wallet.
   - **Browser version mismatch on restore** → restore data files only
     (History/Cookies/Bookmarks/places.sqlite/extensions) into a neutral profile;
     let the app regenerate `Local State`/`Prefs`.
3. **Fix + retry** (one round, non-destructive, logged).
4. **Escalate with options** — if still failing, present 2–3 concrete options in the
   output language and ask. Record the blocker in `data/state.yml`.
5. **Never silently skip `secrets` or `browser` items.** If one fails after the
   fix+retry round, the run is `failed`; say so explicitly and ask how to proceed.

## Verification gates

- **After backup** — `bash scripts/verify.sh --tree <dest>`: dirs non-empty, tars
  readable + sha256 match, drained sqlite integrity ok. PASS = done.
- **After restore** — `verify.sh --tree <new-home> --restored`: dotfiles parse
  (`zsh -n`/`bash -n`), SSH perms 600, catalog roots present. Anything failing →
  `heal` before reporting success.

## Commands (read the mode file first)

- `bash scripts/probe.sh` — detect platform/home/dirs/browsers/drives (for Q&A).
- `bash scripts/backup.sh --dry-run` — preview active selection, no writes.
- `bash scripts/backup.sh [--preset full|--include a,b|--exclude a,b|--ask]`
- `bash scripts/restore.sh --from <root> [--to <home>] [--dry-run|--ask]`
- `bash scripts/verify.sh --tree <path> [--restored]`
- `bash scripts/btrfs.sh status|snapshot|rollback-list` — OS-level rollback helper.

## Headless / non-interactive

Set `auto_confirm: true` and `destination:` in `config/user.yml`, then the wizard
asks once, summarizes, and runs. For scripts/cron: `backup.sh --preset essentials`
needs `destination` present; add `--dry-run` to preview.

## Cross-OS migration notes (Windows / macOS → Linux, or any pair)

- Catalog roots carry per-platform paths; restore resolves the CURRENT platform's
  roots, so a Windows-made backup restores correctly onto Omarchy/Arch/any Linux.
- Browsers: restore into the flatpak (`~/.var/app/...`) or native path that exists on
  the new OS; if the app version differs, SELF-HEAL's browser-neutral-profile rule
  applies. See `docs/migration-checklist.md`.
- Distro layers (system packages, systemd units) are NOT restored — only the home +
  user config. Reinstall apps, then restore config on top. `snapshot.txt` holds the
  reinstall checklist (flatpak apps are portable across distros).

## First run on a fresh clone

1. `cp config/user.example.yml config/user.yml`
2. `/backup-ops onboard` (or `/backup-ops start`) — the wizard asks destination +
   scope, writes `user.yml`, then you're ready.
3. (Recommended) offer `drill` mode to rehearse with no risk.
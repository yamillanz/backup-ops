# Backup-Ops — AI Home-Backup & OS-Migration Command Center

An open-source, CLI-agnostic agent project (mirrors the `career-ops` pattern) that
backs up a home directory, restores it onto a fresh OS, verifies every step, and
**self-heals problems during both backup and restore** using the agent's reasoning.

**Design philosophy: maximally configurable, always.**
- The backup scope, destinations, browser set, migration profile, and even the
  platforms are DATA, not code.
- Everything user-specific lives in `config/user.yml`; the committed catalog
  `config/manifest.yml` is generic and cross-platform (linux / windows / macos / wsl).
- A `/backup-ops start` command drives a conversational wizard: probe → ask with
  typical picks pre-selected → confirm → run → verify.
- Tomorrow you want to migrate Windows→some distro? The same catalog knows Windows
  paths; run `start restore` on the new box. A Debian→Fedora move uses the migration
  profile, package plan, and DE gate.

The method follows the video checklist in `docs/B-cYZ2wV5OQ.txt` and the corrected
command gist: <https://gist.github.com/sec2john/c99ac086b7c1b8516dbc791f38075a70>.

## Opening state (CRITICAL)

On the first message of a session, read `config/manifest.yml` (catalog),
`config/user.yml` (your choices; may be absent on a fresh clone), and
`data/state.yml` (last run, resumability, open issues).

- Missing `config/user.yml` + no state → **onboard** mode: run the `start` wizard to
  produce it.
- `manifest.yml` missing/broken → tell the user it's the committed catalog (git) and
  re-copy from `config/manifest.example.yml` if needed.
- Backup target from `user.yml` not mounted → offer `scan-drives` (`probe.sh` shows
  candidates).
- A backup root contains `migration.yml` (source/target profile, selection, catalog
  hash). Read it before restoring; never assume the local `user.yml` selection is the
  backup's selection.
- Read `config/user.yml` → `migration:` for source/target distro, family, desktop,
  `restore_profile`, and the optional gaming/VM/system flags.

## Core principles

1. **Origin and destination are data.** Family (`debian|arch|fedora|suse|other`) and
   desktop determine package handling and DE gating. Do not copy a whole home across
   families and call it migration.
2. **Never destructive.** Backup copies. Restore writes to the new home (or a staging
   dir in drill). Before any `rm`/`mv`/overwrite, explain and confirm. `--delete`
   never appears without explicit per-run approval.
3. **No automatic system mutation.** Never auto-install packages, never auto-write
   `/etc`, NetworkManager, fstab, hypervisor state, or container volumes, never use
   `verbatim` across families.
4. **Verification is mandatory.** After backup, verify. After restore, verify. A
   backup you haven't verified is a lie. Critical coverage gaps fail the run.
5. **Self-heal, don't stall.** Diagnose → fix → retry once → escalate with concrete
   options (option A / option B), never an open "what now?".
6. **Everything is logged.** `data/run-log.md` (human) + `data/state.yml` (machine).
7. **The catalog is shared code; your user.yml is yours.** Edit the catalog only in
   `onboard`/`regen` when the user approves a new source/root.

## Data Contract

- **User layer (gitignored, personal):** `config/user.yml`, `data/*`,
  `config/user.example.yml` is a template. `migration:` is user-layer data.
- **Backup artifacts (on the destination drive, not committed):** `migration.yml`,
  `backup-info.yml`, `coverage-report.md`, `preflight.txt`, `manifest.sha256`,
  `packages/`, `system-state/`, `system-files/`, `network/`, `virtualization/`,
  `containers/`, `portable/appimages/`, `gaming/`, `fonts/`, `themes/`, source dirs,
  tars.
- **System layer (committed, publish-safe):** `config/manifest.yml` (generic
  catalog), `modes/*.md`, `scripts/*.sh`, `.opencode`, `.agents`, `.claude`, `.qwen`,
  `.cursor`, `config/global-excludes.txt`, `docs/*`, `README.md`, `LICENSE`.

Never write user-specific paths, secrets, or destinations into the system layer.

## Sources of truth

- `config/manifest.yml` — declarative catalog: `sources:` (id, label, kind, enabled,
  dest, platforms roots per OS, include/exclude, `restore_policy`,
  `restore_phase`), `presets:`, `platform:`, `default_preset:`, `safety:`.
- `config/user.yml` — selection (`preset` or `selection: []`), `destination`,
  `language.output`, `auto_confirm`, `migration:` source/target/profile.
- `migration.yml` — written into each backup root: flat source/target keys,
  selection, catalog hash. Restore reads it first.
- `modes/*.md` — per-mode instructions. Read the relevant one before acting.
- `scripts/*.sh` — engine. `lib.sh` renders the catalog, resolves candidate roots
  (`native > flatpak`), and reads migration metadata; the agent may run raw
  `rsync`/`tar`/`sqlite3`/`probe.sh` when needed.
- `data/state.yml` — run state.

## Engine & source kinds

- **dir** — rsync mirror of a whole tree (folders). Candidate roots resolve to the
  first existing; alternates are logged.
- **tar** — single `.tar.gz` + sha256 (config/dotfile blobs; optional include list).
- **drain** — WAL-safe sqlite `.backup` + rsync (browsers: History/places/Cookies).
- **snapshot** — generated collectors:
  - `packages` — native explicit/full, AUR, Flatpak, Snap, install hints
  - `snapshots` — OS/DE versions, fstab, mounts, cron, systemd units/timers
  - `system_files` — selected `/etc` files, manual restore
  - `network` — NetworkManager profiles, 600, manual restore
  - `virtualization` — libvirt/VirtualBox definitions/inventory; disks opt-in
  - `containers` — Docker/Podman inventory + compose + volume-backup script
  - `appimages` — scan/copy `*.AppImage`, exec bit + sha256
  - `gaming_saves` — Ludusavi or detected roots + instructions
  - `audit` — user-owned files outside home, report only
  - `toolchains` — sizes/locations, informational

Each source carries per-platform roots, so the SAME catalog drives Linux, Windows,
macOS, and WSL. Browser sources map per-platform and per-install-format.

## Restore policy & phases

Every source has `restore_policy`:
- `always` — apply automatically.
- `same-de` — apply only when source/target desktop match AND profile is `same-de`
  (or `verbatim`); otherwise stage.
- `manual` — stage under `<to>/restore-manual/<id>`; never write system paths.
- `never` — informational only.

Phases: 10 packages plan, 20 fonts/themes, 30 dotfiles/secrets, 40 app/DE configs,
50 browsers, 60 data, 90 system/manual.

## Mode routing

| User intent | Mode |
|-------------|------|
| "start the backup process", "back up" | `start` (conversational pipeline) |
| "migrate", "change distro", "origin and destination" | `migrate` |
| "clean", "free space", "remove junk" | `clean` |
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

1. **Capture** — exact error/return code/log tail into the run log.
2. **Diagnose root cause**, don't treat symptoms. Real classes:
   - **Disk full / target not mounted** → `df`, remount/switch target, prune excludes,
     split scope. `clean` reports cache/trash/package-cache sizes.
   - **Permission denied on write** (FAT32/exFAT USB) → `--no-perms --chmod=ugo=rwX`
     for that target, or store perms in the tar archive.
   - **Permission denied reading `/etc`/NetworkManager/SSH host keys** → `sudo -n`
     one attempt; otherwise mark `skipped-permission` with the exact manual command.
     Do not fail the whole run.
   - **File changed while copying / live DB** → sqlite `.backup` (WAL-safe) or retry;
     verify `PRAGMA integrity_check`.
   - **sqlite locked** → `PRAGMA wal_checkpoint(TRUNCATE);` then `.backup`.
   - **rsync hardlink across devices** → drop `--link-dest`/`-H` for the run.
   - **Missing source** → log `skipped-missing`, continue; never fail the whole run.
   - **Broken symlink at source** → `rsync -L` or `--copy-unsafe-links`.
   - **Keyring/wallet can't restore** → `~/.local/share/keyrings` copied verbatim +
     documented re-seed; never decrypt someone's wallet. Chromium passwords need it.
   - **Browser version mismatch** → restore data files only
     (History/Cookies/Bookmarks/places.sqlite/extensions) into a neutral profile; let
     the app regenerate `Local State`/`Prefs`.
   - **Package missing on target family** → do not guess a mapping; flag it in
     `packages-to-install.txt`/report and ask for the target package name.
   - **Desktop differs** → stage `desktop_env`; never apply. Same DE but different
     version → require review.
   - **VM running** → stop before disk copy; definitions/XML are safe.
   - **Docker/Podman storage path differs** → use helper-container volume export;
     never assume `/var/lib/docker`.
3. **Fix + retry** (one round, non-destructive, logged).
4. **Escalate with options** — 2–3 concrete options in the output language; record
   the blocker in `data/state.yml`.
5. **Never silently skip `secrets` or `browser` items.** If one fails after the
   fix+retry round, the run is `failed`; say so and ask how to proceed. The coverage
   report's `CRITICAL GAPS` is authoritative.

## Verification gates

- **After backup** — `bash scripts/verify.sh --tree <dest>`:
  selected sources non-empty; tars readable + sha256; sqlite integrity; package
  inventory; AppImage exec+sha256; network/SSH perms; VM XML; compose YAML; no
  cache/trash; migration manifest + catalog hash; `critical_gaps: 0`; no
  `CRITICAL GAPS` in the coverage report. PASS = done.
- **After restore** — `verify.sh --tree <new-home> --restored`: dotfiles parse
  (`zsh -n`/`bash -n`), SSH perms 600, keyring 700, browser sqlite, fonts when
  applied, DE gate (desktop_env not applied across different desktops), migration
  report, package plan, applied-vs-staged reporting. Anything failing → `heal`
  before reporting success.

## Commands (read the mode file first)

- `bash scripts/probe.sh` — platform/home/distro/family/desktop/package manager/
  browsers/gaming/VMs/containers/drives (read-only).
- `bash scripts/clean.sh` — report; `--trash|--cache|--orphans|--flatpak [--yes]`.
- `bash scripts/backup.sh --dry-run` — preview, no writes.
- `bash scripts/backup.sh [--preset full|--include a,b|--exclude a,b|--ask|--force]`
- `bash scripts/restore.sh --from <root> [--to <home>] [--plan-only] [--profile safe|same-de|verbatim]`
- `bash scripts/verify.sh --tree <path> [--restored]`
- `bash scripts/btrfs.sh status|snapshot|rollback-list` — OS-level rollback helper.

## Headless / non-interactive

Set `auto_confirm: true` and `destination:` in `config/user.yml`, then the wizard
asks once, summarizes, and runs. For scripts/cron: `backup.sh --preset essentials`
needs `destination` present; add `--dry-run` to preview. `auto_confirm` never
authorizes destructive cleanup, package installation, or `/etc` writes.

## Cross-OS / cross-family migration notes

- Catalog roots carry per-platform paths; restore resolves the CURRENT platform's
  roots. Candidate lists (`native > flatpak`) resolve to an existing target root;
  install the app first if none exists.
- Package inventories are source-side. Restore generates a target-family plan and
  scripts but never runs them. Package names differ; review.
- Desktop state is gated by `restore_policy: same-de`. Do not copy GNOME/KDE/COSMIC/
  Hyprland configs across desktops.
- Browsers restore data-only. Chromium passwords need the keyring or sync.
- Distro layers (system packages, systemd units) are NOT restored. Reinstall apps,
  then restore config on top. `packages/` + `system-state/` hold the checklist.
- `system_files`, `network`, `virtualization`, `containers`, `appimages`, and
  `gaming_saves` are manual by design.

## First run on a fresh clone

1. `cp config/user.example.yml config/user.yml`
2. `/backup-ops onboard` (or `/backup-ops start`) — asks destination + scope +
   migration target, writes `user.yml`, then you're ready.
3. Recommended: `drill` mode to rehearse with no risk.

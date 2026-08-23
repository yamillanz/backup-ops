# start mode — the interactive backup pipeline

Goal: be the ONE command the user runs to go from "I want to back up / migrate" to
a verified backup on disk. It is conversational: the agent probes the machine, asks
the user a short set of questions with **typical folders pre-selected**, writes the
answers to `config/user.yml`, then backs up and verifies. Nothing runs until every
answer is collected and the user confirms.

Also works for restore/migration: `start restore` runs the same wizard in restore
mode (asks WHERE things should go and WHICH sources, then restores + verifies).

## What to do on `Start backup the process` / `start backup` / `start restore`

1. Say what you're about to do in `language.output` (default `en`), mention the
   detected platform, and run the probe:

   ```bash
   bash scripts/probe.sh
   ```
   Read its output: `platform=`, `home=`, `package_manager=`, `os_release=`,
   `[folders]` present, `[browsers]` present/absent, `[drives]` candidates.

2. **Ask the destination** (the single most important question). Show the detected
   external drives and ask:
   > "Where should the backup live? I see {drive list}. Type the mount path or
   > '/tmp/... ' to use a staging folder for a test."
   Record it into `config/user.yml` as `destination:`.

3. **Ask the scope** with typical picks pre-selected. Present the catalog sources
   from `config/manifest.yml` (rendered by `scripts/lib.sh render_catalog`), grouped:
   - User folders (pre-selected: Documents, Projects, Desktop, Pictures, Videos,
     Music, Public; not pre-selected: Downloads, Games, AppImages)
   - App configs + dotfiles (pre-selected: configs, dotfiles, histories)
   - Secrets (pre-selected: SSH + GPG)
   - Browsers (pre-selected: all present)
   - System state (pre-selected)
   Show **only the sources that exist on this machine** (from probe). For each,
   list it with its `enabled` flag as the default answer. Ask:
   > "Here's what I found. Do you want to keep these defaults, or change the
   > selection? (You can say: 'skip Downloads', 'add Games too', or 'keep all')."
   Update the selection accordingly.

   Two ways to store the choice:
   - Named preset is simplest: keep `preset: essentials|full|minimal` in
     `config/user.yml` (default `essentials`).
   - Precise picks: write `selection: [documents, projects, ..., secrets]` and set
     `preset: ""`.

4. **Confirm the plan** in a table, then once the user says go:
   ```bash
   bash scripts/backup.sh --dry-run
   ```
   show the preview, then ask for final confirmation before the real run:
   ```bash
   bash scripts/backup.sh
   ```
   > "Start it?" (If `config/user.yml` has `auto_confirm: true`, ask once at setup
   > and don't repeat.)

5. **Verify** unconditionally after backup:
   ```bash
   bash scripts/verify.sh --tree <destination>
   ```
   Report per-section ✅/❌. If any ❌ → run `heal` mode; do not claim success.

6. Write the recap (what was backed up, where, sizes, next steps) to
   `data/run-log.md`, update `data/state.yml`, and give the user the one-liners to
   restore later.

## restore variant

Same rhythm, but reversed and with the new-OS questions:

1. Probe the current (new) machine.
2. Ask `--from` (the backup root — on the external drive) and `--to` (new home; default `$HOME`).
3. Show the catalog sources available on the current platform and ask which to
   restore (pre-selected: everything that was in the backup).
4. Dry-run `restore.sh --dry-run`, confirm, run, then `verify.sh --restored`.
5. Notify about cross-platform notes: browser roots remap automatically (see
   `docs/migration-checklist.md`); system state is informational only.

## Flags / non-interactive fast-path

Honor these if present in `config/user.yml` (or repeated in a command):
`auto_confirm`, `preset`, `destination`. When `auto_confirm: true` and a
`destination` is set, skip straight to a confirming summary and run.

## Write to user layer only

`config/user.yml` is where personalization lives (destination, preset/selection,
language, auto_confirm). The committed `config/manifest.yml` catalog is never edited
by this mode. If the probe reveals something the catalog doesn't cover (a weird app
config dir), suggest adding a catalog source and let the user approve the diff.
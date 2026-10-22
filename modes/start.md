# start mode — the interactive backup / migration pipeline

Goal: be the ONE command the user runs to go from "I want to back up / migrate" to
a verified pack on disk. It is conversational: probe the machine, ask a short set of
questions with typical picks pre-selected, write the answers to `config/user.yml`,
then back up and verify. Nothing runs until the user confirms.

Also works for restore/migration: `start restore` runs the same wizard in restore
mode, but restore now starts with `--plan-only`.

## What to do on `start backup` / `start restore`

1. Say what you're about to do in `language.output` (default `en`), mention the
   detected platform, and run:
   ```bash
   bash scripts/probe.sh
   ```
   Read: `platform`, `home`, `os_id`, `family`, `desktop`, `package_manager`,
   `flatpak/snap`, `ludusavi`, `docker/podman`, `virsh/VBoxManage`, `keyring`,
   `fonts_*`, `[folders]`, `[browsers]`, `[gaming]`, `[virtualization]`, `[drives]`.

2. **Ask the destination** (the most important question). Show detected external
   drives and ask for the mount path. Record `destination:` in `config/user.yml`.

3. **Ask the migration profile** (new):
   - Source is detected. Confirm `source.family` and `source.desktop`.
   - Ask the target: distro/family and desktop, or "unknown until I boot the new OS".
   - Ask whether to include gaming libraries, VM disks, and system files.
   Write a `migration:` block:
   ```yaml
   migration:
     source: {platform: auto, distro: auto, family: auto, desktop: auto}
     target: {platform: auto, distro: "", family: "", desktop: ""}
     restore_profile: safe
     include_vm_disks: false
   ```

4. **Ask the scope** with typical picks pre-selected. Present catalogs grouped:
   - User folders (pre-selected: Documents, Projects, Desktop, Pictures, Videos,
     Music, Public, Calibre; not: Downloads, Games)
   - Config + dotfiles (configs, desktop_env, dotfiles, histories, local_bin_user)
   - Secrets (SSH + GPG; never silently skipped)
   - Fonts/themes (user fonts, themes; system fonts are full/manual)
   - Browsers (present ones; profiles + keyring caveat)
   - Packages/system (packages, snapshots, system_files)
   - Full-only: gaming, AppImages, flatpak data, network, virtualization,
     containers, audit, system fonts/binaries
   Show only sources that exist on this machine. Typical picks are `enabled` in the
   catalog. Ask: "keep defaults, or change?".

5. **Offer cleanup** before packing:
   ```bash
   bash scripts/clean.sh
   ```
   Report only. Destructive actions need the flag and `--yes`; see `modes/clean.md`.

6. **Confirm the plan**, then preview:
   ```bash
   bash scripts/backup.sh --dry-run
   ```
   Check the migration profile, destination, estimated payload, candidate roots, and
   selection. Then run:
   ```bash
   bash scripts/backup.sh
   ```

7. **Verify unconditionally**:
   ```bash
   bash scripts/verify.sh --tree <destination>
   ```
   A PASS is required. Review `coverage-report.md`. If `CRITICAL GAPS` exists, the
   run exits non-zero; do not claim success. Run `heal` and retry once.

8. **Recap** what was packed (sizes, coverage, package count, skipped/manual items),
   write `data/run-log.md`, and give the restore one-liners.

## restore variant

Same rhythm, reversed and gated:

1. Probe the new machine.
2. Ask `--from` and `--to` (default `$HOME`).
3. Run plan-only:
   ```bash
   bash scripts/restore.sh --from <root> --to "$HOME" --plan-only
   ```
4. Read `data/migration-report.md`: family change, desktop change, package plan,
   skipped/staged sources.
5. Confirm, run without `--plan-only`, then:
   ```bash
   bash scripts/verify.sh --tree "$HOME" --restored
   ```
6. Notify about manual items: `/etc` files, NetworkManager, VMs/disks, containers,
   AppImages, and Ludusavi saves. DE configs are staged, never applied across DEs.

## Flags / non-interactive fast-path

Honor `auto_confirm`, `preset`, `selection`, `destination`, and `migration` from
`config/user.yml`. With `auto_confirm: true` and a destination set, summarize once
and run. `auto_confirm` never authorizes destructive cleanup, package installation,
or `/etc` writes.

## Write to user layer only

Personalization lives in `config/user.yml` (destination, preset/selection, language,
auto_confirm, migration). The committed catalog is never edited by this mode.

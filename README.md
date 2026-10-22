# Backup-Ops

Back up a home directory, verify it, and restore it onto a fresh OS — **including
cross-distro-family migrations** (Debian/Ubuntu → Arch/Fedora/etc.). Driven by an AI
agent or run directly. The catalog is data; your selection and migration profile live
in `config/user.yml`.

The core rule: **origin and destination matter**. Copying a whole home across distros
carries caches, obsolete configs, and desktop-environment state that can break the new
system. Backup-Ops separates data, app configs, desktop state, secrets, package
inventories, and manual system artifacts so restore can be gated instead of blind.

## What it covers

| Layer | Examples | Restore behavior |
|---|---|---|
| User data | Documents, Projects, Pictures, Videos, Music, Calibre | apply |
| Dotfiles/history | `.zshrc`, `.bashrc`, tmux, git, shell history | apply, parse-checked |
| App configs | `~/.config/<app>` (cache-free) | apply |
| Desktop state | dconf, KDE/Plasma, COSMIC, Hyprland | **same-DE only**, otherwise staged |
| Secrets | `~/.ssh`, `~/.gnupg`, keyrings | apply, permissions enforced |
| Fonts/themes | user fonts, themes, icons, cursors | apply before configs |
| Browsers | Firefox, Chromium, Brave, Chrome, Edge, Opera, Vivaldi, Zen, LibreWolf | data profile only; keyring caveat |
| Packages | native explicit/full, AUR, Flatpak, Snap | inventory + generated target plan, never auto-installed |
| Gaming | Steam, Lutris, Heroic, Ludusavi saves | opt-in, large |
| AppImages | scan/copy `*.AppImage` | manual restore |
| System files | fstab, hosts, sshd, udev, sysctl, cron, units | **manual only** |
| Network | NetworkManager profiles, VPN/WiFi | **manual only**, 600 |
| VMs/containers | libvirt XML, VirtualBox, compose, volumes | definitions/inventory; disks opt-in |

## Safety rules

- Backup copies; restore writes under `--to`; system paths are never auto-written.
- Desktop-environment state is not restored across different desktops.
- Package install scripts are generated, not executed.
- Cleanup is report-first; destructive actions require a named flag and `--yes`.
- A backup run with critical coverage gaps exits non-zero.
- No cache/trash payload is packed.

## Quick start — backup

```bash
cp config/user.example.yml config/user.yml
# edit destination + preset or selection; add migration target if known

bash scripts/probe.sh
bash scripts/clean.sh                 # report only
bash scripts/backup.sh --dry-run
bash scripts/backup.sh
bash scripts/verify.sh --tree <destination>
```

`backup.sh` writes:

- `migration.yml` — source/target profile, selection, catalog hash
- `coverage-report.md` — detected vs packed; `CRITICAL GAPS` means failure
- `packages/` — native explicit/full, AUR, Flatpak, Snap, install hints
- `system-state/`, `system-files/`, `network/`, `virtualization/`, `containers/`
- `portable/appimages/`, `gaming/`, `fonts/`, `themes/`
- `manifest.sha256` — every file

The engine refuses same-disk-as-`/` destinations unless `--force`, checks estimated
payload + 10% free space, and logs alternates for native/flatpak candidate roots. A
backup stops when free space is below `free_space_min_gb` (30 by default); `--force`
is the explicit override.

## Clean before packing

```bash
bash scripts/clean.sh
```

Reports home caches/trash, package-manager caches, orphan-package preview, and unused
Flatpak runtimes. Nothing is deleted by default. Explicit actions:

```bash
bash scripts/clean.sh --cache --yes
bash scripts/clean.sh --orphans --yes
bash scripts/clean.sh --flatpak --yes
bash scripts/clean.sh --trash --yes
```

Never run `rm -rf` on a home directory; never clean browser profiles, keyrings, or
projects.

## Cross-distro migration

Add the destination intent to `config/user.yml` (or leave target blank and let restore
probe the new machine):

```yaml
migration:
  source:
    platform: auto
    distro: auto
    family: auto
    desktop: auto
  target:
    platform: auto
    distro: fedora
    family: fedora
    desktop: kde
  restore_profile: safe      # safe | same-de | verbatim
  include_vm_disks: false
```

On the destination:

```bash
bash scripts/restore.sh --from <backup-root> --to "$HOME" --plan-only
# read data/migration-report.md, install the apps, then:
bash scripts/restore.sh --from <backup-root> --to "$HOME"
bash scripts/verify.sh --tree "$HOME" --restored
```

`--plan-only` writes no target files. It produces `migration-report.md` and the package
plan. The default `safe` profile stages `desktop_env` instead of applying it. Use
`--profile same-de` only when the desktop and version actually match; `verbatim` is
intentionally dangerous. A backup without `migration.yml` is treated as legacy:
safe-only, with app configs staged under `restore-manual/configs`.

### Package continuity

Restore reads `packages/native-apps.txt` (filtered) or `native-explicit.txt` and
generates `packages-to-install.txt`, `install-packages.sh`, and Flatpak equivalents.
It does **not** run them. Package names differ across families; review first.

### Browsers and the keyring

Install the browser on the target first. Restore uses an existing browser root only.
Profiles restore data files; Chromium-variant passwords need the original keyring
(`~/.local/share/keyrings`) or browser sync. Without it, tabs/bookmarks return but
saved passwords will not decrypt.

### Desktop environments

Do not copy DE configs across desktops. `desktop_env` is a separate tar with policy
`same-de`; on a mismatch it is staged under `<to>/restore-manual/desktop_env/` for
review. Same DE still requires matching versions and the explicit `same-de` profile.
Install fonts/themes/extensions first, then import. GNOME: `dconf dump/load`; KDE:
the relevant `.ini` files or `konsave`.

### Outside the home

`system_files` copies selected `/etc` files (fstab, hosts, sshd, udev, sysctl, cron,
units) for review. `network` copies NetworkManager profiles at 600. `virtualization`
exports XML/inventory; disks only with `include_vm_disks: true` and VMs powered off.
`containers` copies compose files and generates a volume-backup script. None of this
is auto-restored.

## Verify

```bash
bash scripts/verify.sh --tree <backup-root>
bash scripts/verify.sh --tree "$HOME" --restored
```

The backup's own selection is authoritative. Checks include manifests/checksums,
tars, sqlite integrity, package inventory, AppImage exec+sha256, network/SSH
permissions, VM XML, compose YAML, no cache/trash, migration metadata, coverage gaps,
dotfile parsing, keyring/SSH permissions, fonts, and the desktop gate.

## Configuration

Two files matter:

```yaml
# config/user.yml — personal, gitignored
language: {output: en}
preset: essentials        # essentials | full | minimal
selection: []             # explicit ids override preset
destination: ""
auto_confirm: false
migration: { ... }        # source/target profile
```

`config/manifest.yml` is the committed catalog: sources, per-platform roots,
include/exclude rules, presets, restore policies, and safety knobs. Add a source there
to extend coverage; never write personal paths into it.

## Requirements

Required: `bash`, `rsync`, `tar`, `sqlite3`.
Optional collectors/checks: `flatpak`, `snap`, `ludusavi`, `virsh`, `VBoxManage`,
`docker`/`podman`, `python3` (XML/YAML validation), `gio`/`trash-cli` (trash cleanup).

## Security

Backups are unencrypted by default; protect the drive. Secrets tar and NetworkManager
dumps are permission-tight, but the medium itself is the boundary. Do not upload the
backup root to a shared location. SSH host keys and WiFi/VPN profiles are sensitive.

## Development

See `CONTRIBUTING.md` and `AGENTS.md`. The catalog is data; the engine reads it. Run
`bash -n scripts/*.sh` and a fixture backup→verify→restore→verify before claiming a
change works.

MIT licensed.

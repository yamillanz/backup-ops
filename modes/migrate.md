# migrate mode — origin distro → destination distro

Goal: plan and execute a **cross-family migration**, not just a home copy. The video's
core rule applies: Debian/Ubuntu → Arch/Fedora is not `cp ~`; package names, config
formats, and desktop environments differ.

## Inputs

Read in this order:

1. `config/manifest.yml` — catalog + presets + restore policies.
2. `config/user.yml` — `migration:` source/target profile, selection, destination.
3. `data/state.yml` — last run, open issues.
4. `bash scripts/probe.sh` — current machine facts (family, desktop, package manager,
   browsers native/flatpak, gaming, VMs, containers, drives).

If `migration.target.*` is blank, ask only what is genuinely unknown:
- target distro/family (e.g. Fedora / fedora, Arch / arch)
- target desktop (e.g. KDE / kde), or "same as source"
- whether to include gaming libraries, VM disks, and system files

Do not guess these; record them in `config/user.yml` (user layer).

## Sequence

1. **Clean** (optional but recommended): `bash scripts/clean.sh`, then explicit
   opt-in actions. See `modes/clean.md`.

2. **Preview the pack**:
   ```bash
   bash scripts/backup.sh --dry-run
   ```
   Check the migration profile, estimated payload, source candidates, and the
   selected sources. Resolve disk-space or selection issues before writing.

3. **Back up**:
   ```bash
   bash scripts/backup.sh
   ```
   The engine writes:
   - `migration.yml` — source/target profile, selection, catalog hash
   - `coverage-report.md` — detected vs packed; `CRITICAL GAPS` means the run failed
   - `packages/` — native explicit/full, AUR, Flatpak, Snap inventories
   - `system-state/`, `system-files/`, `network/`, `virtualization/`, `containers/`
   - `portable/appimages/`, `gaming/`, `fonts/`, `themes/`
   - `manifest.sha256`

4. **Verify**:
   ```bash
   bash scripts/verify.sh --tree <destination>
   ```
   PASS is required. Fix critical gaps (browsers, packages, secrets, system files)
   before leaving the source machine.

5. **On the destination**, install the OS and the apps. Then:
   ```bash
   bash scripts/restore.sh --from <backup-root> --to "$HOME" --plan-only
   ```
   Read `data/migration-report.md`:
   - family change → package names need review
   - desktop change → `desktop_env` is staged, not applied
   - browser install format → install the browser first
   - fonts/themes → restore before DE configs
   - system/network/VM/container → manual only

6. **Apply**:
   ```bash
   bash scripts/restore.sh --from <backup-root> --to "$HOME"
   ```
   Default profile is `safe`. Use `--profile same-de` only when the desktop and
   version genuinely match. Never use `verbatim` across distro families.

7. **Install packages from the generated plan** (manual review first):
   ```bash
   less "$HOME/packages/packages-to-install.txt"
   bash "$HOME/packages/install-packages.sh"
   ```
   The project never installs packages automatically.

8. **Verify restored**:
   ```bash
   bash scripts/verify.sh --tree "$HOME" --restored
   ```

## Hard rules

- Do not restore `desktop_env` across different desktops.
- Do not auto-write `/etc`, NetworkManager profiles, fstab, or hypervisor state.
- Do not run VM disk copies while a VM is running.
- Do not assume Chromium passwords survive without the keyring.
- Do not silently skip browsers/secrets; a gap makes the run failed.
- Do not copy caches, trash, or nested `node_modules` into the pack.

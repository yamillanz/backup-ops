# Migration checklist (any OS → any OS)

Pulled from `system-state/snapshot.txt` at restore time. This is a living doc the
agent updates during `regen` / after `restore`.

Order matters: **OS is installed → apps reinstalled → backup-ops restores your home
data on top**.

## 0. Before erasing the old OS

1. `/backup-ops start` → backup to an external drive → `/backup-ops verify`.
2. Keep the drive unplugged until the new OS is installed.
3. (Optional, btrfs only) `bash scripts/btrfs.sh snapshot pre-migration`.

## 1. Fresh install

- Detect package manager on the new box: `pacman`/`yay` (Arch/Omarchy), `apt`
  (Debian/Ubuntu/Pop), `dnf` (Fedora), `brew` (macOS), `winget` (Windows).
- Desktop environment differs across distros (GNOME, KDE, COSMIC...). Restored
  config for an absent DE is inert until that DE is installed — harmless.

## 2. Reinstall apps (source: system-state snapshot)

- **Flatpaks are portable**: `flatpak list --app` (captured at backup) → reinstall
  the same IDs on any Linux (`flatpak install flathub <id>`).
- **APT/pacman/dnf/brew native packages**: match by name
  (`pacman -Ss <name>`, `yay -S <name>`, `dnf install`, etc.).
- **Toolchains** (`.nvm`, `.rustup`, `.cargo`, `.sdkman`, `go`, `.bun`, `.npm`) are
  re-installed, not restored. Sizes recorded in the snapshot for reference.

## 3. Restore your data

On the new machine: `/backup-ops start restore` (or
`bash scripts/restore.sh --from <backup-root>`), then `/backup-ops verify --restored`.

The catalog remaps every source to the CURRENT platform — a Windows backup restores
correctly onto Linux, and vice versa.

## 4. Browsers (the fiddly part)

- **Chromium-variants** (Brave/Chrome/Edge/Opera/Vivaldi): profiles restore to
  `~/.var/app/<id>/config/<name>/` (Linux flatpak) or `%LOCALAPPDATA%/<name>/` /
  `~/Library/Application Support/<name>/` as appropriate. Install the same browser
  first; then the profile (History, Cookies, Bookmarks, Login Data, extensions)
  drops into place.
- **Version mismatch** ("Your profile can't be loaded"): the agent's `heal` mode
  restores data files (History/Cookies/Bookmarks) into a **neutral** profile instead
  of forcing `Local State`/`Prefs`. Ask `/backup-ops heal`.
- **Firefox-style** (Firefox, Zen, LibreWolf): profiles (incl. `places.sqlite`) restore
  verbatim; first launch migrates them.

## 5. Secrets

- `~/.ssh`: restored with keys `0600` / dir `0700`. Matches the backup.
- `~/.gnupg`: `0700` dir / `0600` keys; smoke-test with `gpg --list-keys`.
- Keyring (`~/.local/share/keyrings`) is copied verbatim; the desktop may re-seed it
  at first login (unlock with your login password — that is normal).

## 6. systemd user units

`systemctl --user list-unit-files` was snapshotted. Re-enable what you need with
`systemctl --user enable --now <unit>`; don't copy enable-links blindly. (Windows:
services/startup entries — restore equivalents manually.)

## 7. Post-migration hygiene

- `/backup-ops verify --restored`
- Anything broken (a config pointing at an old path, renamed flatpak id) →
  `/backup-ops heal`.
- Keep the external drive until you've lived on the new OS for a week.
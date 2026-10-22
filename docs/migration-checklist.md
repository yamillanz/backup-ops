# Migration checklist (any distro → any distro)

Source material: [the video](https://www.youtube.com/watch?v=B-cYZ2wV5OQ) and its
[command gist](https://gist.github.com/sec2john/c99ac086b7c1b8516dbc791f38075a70).
The gist is a cookbook; this checklist keeps the method and fixes the unsafe/fragile
commands.

Order matters: **clean → pack → verify → install OS → reinstall apps → restore data →
restore app configs → gate desktop state → verify**.

## 0. Before erasing the old OS

1. `bash scripts/clean.sh` — report caches, trash, package orphans, unused Flatpaks.
   Destructive actions require a flag + `--yes`. Do not `rm -rf` a home directory.
2. Run `backup` with the migration profile set (source is auto-detected; target may be
   known or `unknown` until the new OS boots).
3. `bash scripts/verify.sh --tree <backup-root>` must PASS. Review
   `coverage-report.md`; `CRITICAL GAPS` means the run failed.
4. Keep the drive unplugged until the new OS is installed.
5. Optional Btrfs: `bash scripts/btrfs.sh snapshot pre-migration`.

## 1. Record the migration profile

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
  restore_profile: safe
  include_vm_disks: false
```

Families: `debian`, `arch`, `fedora`, `suse`, `other`. The family determines package
manager and package-name expectations. The desktop determines whether DE state may be
applied. Do not guess; set the target when known.

## 2. Package inventory (corrected commands)

The backup's `packages/` directory is generated automatically. This is what it does
per family, and the safe manual equivalents:

### Debian/Ubuntu/Pop

```bash
apt-mark showmanual | sort -u > native-explicit.txt
dpkg-query -W -f='${Package}\t${Version}\n' | sort > native-full.tsv
```

Filtering for a human "apps" list must be anchored. An unanchored `grep -v lib` drops
`libreoffice` and `calibre`. Use:

```bash
grep -vE '^(lib|gir1|gstreamer|python3?-|perl-|ruby-|qt[0-9]?-|fonts?-|font-)([:_-]|$)' \
  native-explicit.txt > native-apps.txt
```

Keep the unfiltered list; review the filtered one.

### Arch

```bash
pacman -Qqe  | sort -u > native-explicit.txt   # explicit, all repos
pacman -Qqem | sort -u > aur-explicit.txt      # explicit foreign/AUR
pacman -Q    | sort      > native-full.tsv     # full inventory
```

`-Qne`/`-Qme` are explicit native/foreign; `-Qdtq` lists orphans. Do not run
`pacman -Rns $(pacman -Qdtq)` blindly: review the orphan list first.

### Fedora/RHEL

```bash
dnf repoquery --userinstalled --qf '%{name}\n' | sort -u > native-explicit.txt
rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' | sort > native-full.tsv
```

`dnf history userinstalled` output is version-dependent; use the repoquery form when
available. `dnf remove $(dnf repoquery --extras)` should be reviewed, not pasted
blindly.

### Flatpak / Snap

```bash
flatpak list --app --columns=application,version,branch,origin | sort > flatpak.tsv
snap list | awk 'NR>1{print $1}' | sort -u > snap.txt
```

Flatpak IDs are portable across distros. Restore generates
`flatpaks-to-install.txt`; it does not install them.

## 3. Home data

- Data first: Documents, Projects, Pictures, Videos, Music, Calibre.
- Exclude caches, trash, `node_modules`, build outputs, and browser caches.
- Do not copy the whole home blindly: it carries obsolete configs and DE conflicts.
- Verify tars/checksums and directory non-emptiness.

## 4. Shell, dotfiles, fonts

- Shell: `.zshrc`, `.zshenv`, `.zprofile`, `.bashrc`, `.bash_profile`, `.profile`,
  `.bash_aliases`, `.inputrc`, `.tmux.conf`, `.p10k.zsh`, `.oh-my-zsh`.
- Tool configs under `~/.config`: alacritty, kitty, zellij, starship, btop, htop, bat,
  fastfetch, nvim; plus `.vimrc`.
- History files are useful but not critical.
- Fonts: `~/.local/share/fonts` and legacy `~/.fonts`; system fonts under
  `/usr/local/share/fonts` and `/usr/share/fonts` are manual.
- Themes/icons/cursors: restore before app/DE configs and rebuild the font cache
  (`fc-cache -f`) on the target.

## 5. Desktop environment (the sharp edge)

Do **not** copy DE configs across desktops. Ignore/omit:

- `~/.config/dconf/` (GNOME)
- `~/.config/kdeglobals`, `plasmarc`, `kglobalshortcutsrc`, `kwinrc`, `kwinrulesrc`,
  `kscreenlockerrc`, `plasma-org.kde.plasma.desktop-appletsrc`
- `~/.config/cosmic/`
- `~/.config/hypr/`
- `~/.config/gnome-shell/`
- GTK/Qt theme dirs when the DE changes

Backup-Ops stores these in `desktop_env` (not `configs`) with policy `same-de`:

- Different DE → staged under `<to>/restore-manual/desktop_env/`
- Same DE + matching version + `--profile same-de` → applied
- Same DE but different major version → review; do not assume

Export/import helpers:

```bash
# GNOME: export only the GNOME branch
dconf dump /org/gnome/ > gnome_settings.dconf
# on the target, after installing extensions/themes:
dconf load /org/gnome/ < gnome_settings.dconf

# KDE: copy only the relevant .ini files, or use konsave
cp -v ~/.config/kdeglobals ~/.config/plasmarc ~/.config/kglobalshortcutsrc ...
```

Install fonts, themes, icon packs, and extensions **before** importing DE settings.

## 6. Browsers

Two strategies:

1. **Cloud sync** — Firefox Sync / Brave Sync / Google account. Fast; does not always
   carry active cookies, `about:config`, or flags.
2. **Physical profile** — exact session, cookies, local storage. This is what
   Backup-Ops copies.

Paths (flatpak first, native fallback):

- Firefox: `~/.var/app/org.mozilla.firefox/.mozilla/firefox` →
  `~/.mozilla/firefox`
- Brave: `~/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser` →
  `~/.config/BraveSoftware/Brave-Browser`
- Chrome: `~/.var/app/com.google.Chrome/config/google-chrome` →
  `~/.config/google-chrome`
- Edge: `~/.var/app/com.microsoft.Edge/config/microsoft-edge` →
  `~/.config/microsoft-edge`
- Opera/Vivaldi/Zen/LibreWolf/Chromium: equivalent flatpak/native pairs.

Keyring warning: Chromium variants encrypt saved passwords with the system keyring
(GNOME Keyring / KWallet / libsecret). Copying the profile without the keyring means
tabs/bookmarks return but passwords do not decrypt. Restore
`~/.local/share/keyrings` first, or use browser sync for credentials. Never try to
decrypt someone else's wallet.

Version mismatch: restore data files (History/Cookies/Bookmarks/places.sqlite/
extensions) into a neutral profile; let the app regenerate `Local State`/`Prefs`.

## 7. Gaming

- **Saves**: use Ludusavi (`ludusavi backup --path <dir> --force`); it knows Steam,
  Lutris, Heroic, Wine/Proton prefixes. If it is not installed, the backup lists
  detected roots and instructions.
- **Steam**: `steamapps` under `~/.local/share/Steam`, `~/.steam/steam`, or the
  flatpak `~/.var/app/com.valvesoftware.Steam/.local/share/Steam`. Copying
  `steamapps/common` avoids re-downloading games; it is huge, so opt in.
- **Lutris**: games in `~/Games`; metadata/database in `~/.local/share/lutris` or
  flatpak `~/.var/app/net.lutris.Lutris/data/lutris`. Copying only `~/Games` leaves
  Lutris looking empty.
- **Heroic**: games under `~/Games/Heroic` (also `epic-games-store`, `gog-games`);
  config in `~/.config/heroic` or flatpak config; runner data in the flatpak data
  dir.
- Consider a dedicated games partition to avoid moving hundreds of GB each migration.
- Do not copy caches (`shadercache`, `downloading`, `temp`) or flatpak mirror/symlink
  trees blindly.

## 8. Outside the home (manual)

Backup-Ops copies these for review; restore never writes them automatically.

- `/etc/fstab` — review; do not paste UUIDs from another machine.
- `crontab -l`, `sudo crontab -l`, `/etc/cron.*`, systemd timers.
- User units: `~/.config/systemd/user/`; system units: `/etc/systemd/system/`
  (the gist's `sudo cp -r ~/.config/systemd/user/*` is wrong).
- `~/.local/bin`, `~/.local/sbin`, `/usr/local/bin`, `/usr/local/sbin`.
- `/etc/hosts`, `/etc/ssh/sshd_config`, SSH **host** keys (sensitive).
- `/etc/udev/rules.d`, `/etc/sysctl.d`, `/etc/modprobe.d`, limits.
- NetworkManager: `system-connections/`, `NetworkManager.conf`, `conf.d/`,
  `dispatcher.d/`; contains WiFi/VPN secrets, keep 600. Do not copy the whole
  `/etc/NetworkManager` tree including runtime files.

## 9. Virtual machines

- Power VMs **off** first.
- libvirt: `virsh list --all --name`, `virsh dumpxml <vm>`, `virsh net-dumpxml <net>`.
- Disks: `rsync -a --sparse /var/lib/libvirt/images/...` (qcow2 stays sparse).
- VirtualBox: copy `~/VirtualBox VMs` with VMs off, or export OVA:
  `VBoxManage export "<vm>" -o <vm>.ova`.
- Definitions are small; disks are huge. Backup-Ops copies definitions/inventory by
  default and disks only with `include_vm_disks: true`.

## 10. Containers

- Save compose files (`docker-compose.yml`, `compose.yaml`, etc.) with their paths.
- Inventory containers/images/volumes.
- Dump named volumes with a helper container:
  ```bash
  docker run --rm -v <volume>:/data -v "$OUT":/backup alpine \
    tar -czf "/backup/<volume>.tar.gz" -C /data .
  ```
  Do not assume `/var/lib/docker/volumes` (rootless Docker/Podman differ). Backup-Ops
  generates a reviewable `backup-volumes.sh`; it does not dump volumes automatically.

## 11. AppImages

- Scan by extension, not just `~/AppImages`; copy with mode preserved and sha256.
- Backup-Ops scans home and common system locations, copies to
  `portable/appimages/files/`, chmod +x, and records `appimages.tsv`.
- Restore is manual: copy what you need to `~/AppImages/`; do not execute unknown
  AppImages from an unverified path.

## 12. Standalone audit

Find user-owned files outside `$HOME` to catch `/opt`, `/usr/local/share`, etc.:

```bash
find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
  -o -path /tmp -o -path /media -o -path /mnt -o -path /home \) -prune \
  -o -uid "$(id -u)" -print0 2>/dev/null |
  xargs -0 -r -n1 dirname | sort -u
```

`sort -u` is correct; the gist's `uniq -d` only shows duplicate parents. Review the
parent list; do not blindly copy `/opt` ISOs.

## 13. Restore order

1. Package plan: review `packages-to-install.txt`; run `install-packages.sh` manually.
2. Fonts/themes.
3. Dotfiles, histories, secrets (perms 700/600).
4. App configs; `desktop_env` only on matching DE + `same-de`.
5. Browsers (install first; keyring before profile).
6. Data.
7. Manual: `/etc`, network, VMs, containers, AppImages, saves.

## 14. Verify on the target

```bash
bash scripts/verify.sh --tree "$HOME" --restored
```

Check dotfiles parse, SSH/keyring perms, browser sqlite, fonts, DE gate, migration
report, package plan. If something breaks, `/backup-ops heal`; do not claim success
without a PASS.

## Gist command corrections

- Anchor package filters (`^lib`/`^gir1`/…), not substring `lib`; keep raw inventories.
- Use `dpkg-query -W` (installed) rather than `dpkg --get-selections` (includes states).
- Preserve AppImage mode; do not leave root-owned files in the staging dir.
- Copy browser profile **contents**, not the profile directory into another directory.
- Copy system units from `/etc/systemd/system`, not `~/.config/systemd/user` with sudo.
- Quote `$HOME`, not `~`, inside command substitutions.
- Use `sort -u`, not `uniq -d`, for the stray-parent audit.
- Export Docker volumes with a helper container; do not assume the storage driver path.
- `rsync --sparse` for qcow2; VMs off first.

#!/usr/bin/env bash
# backup-ops: clean.sh — pre-migration cleanup REPORT, with explicit opt-in
# actions. Default is report-only. Nothing destructive runs without a named
# flag AND --yes. This script never touches user data outside the trash and
# package-manager caches.
#
# Usage:
#   clean.sh                     # report sizes / orphans
#   clean.sh --trash --yes       # empty the user trash (gio/trash-empty)
#   clean.sh --cache --yes       # package-manager cache only
#   clean.sh --orphans --yes     # apt/pacman/dnf autoremove of orphans
#   clean.sh --flatpak --yes     # flatpak uninstall --unused
#   clean.sh --all --yes         # all of the above

set -uo pipefail
BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

DO_TRASH=0; DO_CACHE=0; DO_ORPHANS=0; DO_FLATPAK=0; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --trash) DO_TRASH=1; shift ;;
    --cache) DO_CACHE=1; shift ;;
    --orphans) DO_ORPHANS=1; shift ;;
    --flatpak) DO_FLATPAK=1; shift ;;
    --all) DO_TRASH=1; DO_CACHE=1; DO_ORPHANS=1; DO_FLATPAK=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

home="$(expand_home '~')"
pm="$(pkg_manager)"
echo "cleanup report — $(date -Iseconds)"
echo "home=$home package_manager=${pm:-unknown}"
echo

size_of() { if [[ -e "$1" ]]; then du -sh "$1" 2>/dev/null; else echo "0	$1 (absent)"; fi; }
echo "## Home caches (report only)"
size_of "$home/.cache"
size_of "$home/.local/share/Trash"
size_of "$home/.local/share/Trash/files"
size_of "$home/.local/share/Trash/info"
size_of "$home/.npm/_cacache"
size_of "$home/.cargo/registry/cache"
size_of "$home/.cache/pip"
echo

echo "## Package-manager caches"
case "$pm" in
  apt) size_of /var/cache/apt/archives ;;
  pacman) size_of /var/cache/pacman/pkg ;;
  dnf) size_of /var/cache/dnf ;;
  zypper) size_of /var/cache/zypp ;;
  *) echo "0	no supported package cache" ;;
esac
echo

echo "## Orphans (report)"
case "$pm" in
  apt)
    echo "-- apt autoremove (dry-run) --"
    apt-get -s autoremove --purge 2>/dev/null | sed -n '/The following packages will be REMOVED:/,/^[0-9]/p' || echo "no apt data"
    ;;
  pacman)
    echo "-- pacman orphan packages --"
    pacman -Qdtq 2>/dev/null || echo "none"
    ;;
  dnf)
    echo "-- dnf autoremove (dry-run) --"
    dnf autoremove --assumeno 2>/dev/null | tail -20 || echo "no dnf data"
    ;;
  *) echo "no supported package manager" ;;
esac
echo

echo "## Flatpak unused (report)"
if command_present flatpak; then
  flatpak uninstall --unused --dry-run 2>/dev/null || echo "flatpak dry-run unavailable"
else
  echo "flatpak not installed"
fi
echo

# --- destructive actions ------------------------------------------------------
if [[ $DO_TRASH -eq 0 && $DO_CACHE -eq 0 && $DO_ORPHANS -eq 0 && $DO_FLATPAK -eq 0 ]]; then
  echo "Report only. Nothing was deleted."
  echo "Opt in explicitly: --trash --yes, --cache --yes, --orphans --yes, --flatpak --yes."
  exit 0
fi
if [[ $YES -eq 0 ]]; then
  echo "ERROR: destructive cleanup requested without --yes. Nothing was deleted." >&2
  exit 2
fi

run_sudo() {
  if sudo -n true 2>/dev/null; then sudo -n "$@"; else echo "SKIP (no non-interactive sudo): $*" >&2; return 1; fi
}

if [[ $DO_TRASH -eq 1 ]]; then
  if command_present gio; then
    echo "empty trash: gio trash --empty"
    gio trash --empty && echo "trash emptied"
  elif command_present trash-empty; then
    echo "empty trash: trash-empty"
    trash-empty && echo "trash emptied"
  else
    echo "SKIP: install gio (glib2) or trash-cli to empty trash safely." >&2
  fi
fi

if [[ $DO_CACHE -eq 1 ]]; then
  case "$pm" in
    apt) run_sudo apt-get clean && echo "apt cache cleaned" ;;
    pacman) run_sudo pacman -Sc --noconfirm && echo "pacman cache cleaned (current versions kept)" ;;
    dnf) run_sudo dnf clean all && echo "dnf cache cleaned" ;;
    zypper) run_sudo zypper clean --all && echo "zypper cache cleaned" ;;
    *) echo "SKIP: no supported package cache" ;;
  esac
fi

if [[ $DO_ORPHANS -eq 1 ]]; then
  case "$pm" in
    apt) run_sudo apt-get autoremove --purge -y && echo "apt orphans removed" ;;
    pacman)
      orphans="$(pacman -Qdtq 2>/dev/null || true)"
      if [[ -n "$orphans" ]]; then
        # shellcheck disable=SC2086
        run_sudo pacman -Rns $orphans && echo "pacman orphans removed"
      else
        echo "no pacman orphans"
      fi
      ;;
    dnf) run_sudo dnf autoremove -y && echo "dnf orphans removed" ;;
    *) echo "SKIP: no supported package manager" ;;
  esac
fi

if [[ $DO_FLATPAK -eq 1 ]]; then
  if command_present flatpak; then
    flatpak uninstall --unused -y && echo "unused flatpak runtimes removed"
  else
    echo "SKIP: flatpak not installed"
  fi
fi

echo "cleanup finished."

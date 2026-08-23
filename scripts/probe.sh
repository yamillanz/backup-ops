#!/usr/bin/env bash
# backup-ops: probe.sh — inspect THIS machine and print a machine-readable
# proposal (platform, home, folders, browsers, drives) the `start` wizard uses
# to ask questions with typical picks pre-selected. Read-only: no writes.

set -uo pipefail
BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

plat="$(detect_platform)"
home="$(expand_home '~')"

echo "platform=$plat"
echo "home=$home"

case "$plat" in
  linux|wsl)
    echo "package_manager=$( { which pacman yay apt dnf 2>/dev/null; } | head -1 )"
    echo "os_release=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
    ;;
  windows)
    echo "package_manager=winget"
    echo "os_release=$(powershell.exe -NoProfile -Command '(Get-CimInstance Win32_OperatingSystem).Caption' 2>/dev/null | tr -d '\r')"
    ;;
  macos)
    echo "package_manager=brew"
    echo "os_release=$(sw_vers -productVersion 2>/dev/null)"
    ;;
esac

# --- available user folders (typical picks pre-selected) ----------------------
echo "[folders]"
for f in Documents Projects Desktop Pictures Videos Music Public Downloads Games; do
  for cand in "$home/$f" "$home/Imágenes"; do
    if [[ -d "$cand" ]]; then echo "folder|$cand"; break; fi
  done
done

# --- browsers present ---------------------------------------------------------
echo "[browsers]"
browser_rows "$plat" | while read -r name root; do
  r="$(expand_home "$root")"
  if [[ -d "$r" ]]; then echo "browser|$name|present|$r"; else echo "browser|$name|absent|$r"; fi
done

# --- backup drives (external, different from /) -------------------------------
echo "[drives]"
case "$plat" in
  linux|wsl)
    root_dev="$(df -P / 2>/dev/null | tail -1 | awk '{print $1}')"
    df -P 2>/dev/null | awk 'NR>1 && $6 ~ /^\/media\/|\/mnt\// {print $1 "|" $6 "|" $4}' | sort -u | while IFS='|' read -r dev mnt avail; do
      [[ "$dev" == "$root_dev" ]] && continue
      echo "drive|$mnt|free=${avail}"
    done
    # any removable block devices not mounted?
    { lsblk -o NAME,TYPE,MOUNTPOINT,SIZE -n -r 2>/dev/null || true; } | while read -r name type mnt size; do
      if [[ "$type" == "disk" ]]; then echo "drivehint|$name|$size|mount=${mnt:-none}"; fi
    done
    ;;
  windows)
    powershell.exe -NoProfile -Command "Get-Volume | Where-Object {\$_.DriveLetter} | Select-Object DriveLetter,@{n='SizeGB';e={[math]::Round(\$_.Size/1GB)}}| Format-Table -HideTableHeaders" 2>/dev/null | tr -d '\r' | grep -E '^[A-Z] ' || true
    ;;
  macos)
    # shellcheck disable=SC2010
    df -h 2>/dev/null | grep -E '^/dev/disk|Mounted' | grep -v '/System/Volumes' || true
    ;;
esac
echo "[end]"
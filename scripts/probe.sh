#!/usr/bin/env bash
# backup-ops: probe.sh — inspect THIS machine and print a machine-readable
# proposal (platform, migration source profile, folders, browsers, gaming,
# virtualization, drives) the `start` wizard uses to ask questions with
# typical picks pre-selected. Read-only: no writes.

set -uo pipefail
BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

plat="$(detect_platform)"
home="$(expand_home '~')"

present_absent() { command_present "$1" && echo present || echo absent; }
first_of() { local c; for c in "$@"; do command_present "$c" && { echo "$c"; return 0; }; done; echo ""; }
join_list() { local IFS='|'; printf '%s' "$*"; }

echo "platform=$plat"
echo "home=$home"
echo "uid=$(id -u 2>/dev/null)"
echo "sudo_noninteractive=$(sudo -n true 2>/dev/null && echo yes || echo no)"

case "$plat" in
  linux|wsl)
    echo "package_manager=$(pkg_manager)"
    echo "os_release=$(os_release_field PRETTY_NAME)"
    echo "os_id=$(distro_id)"
    echo "os_like=$(distro_like)"
    echo "family=$(distro_family)"
    echo "desktop=$(desktop_name)"
    echo "desktop_version=$(desktop_version)"
    echo "session_type=${XDG_SESSION_TYPE:-unknown}"
    echo "flatpak=$(present_absent flatpak)"
    echo "snap=$(present_absent snap)"
    echo "ludusavi=$(present_absent ludusavi)"
    echo "docker=$(present_absent docker)"
    echo "podman=$(present_absent podman)"
    echo "virsh=$(present_absent virsh)"
    echo "vbox=$(present_absent VBoxManage)"
    kr="$(first_of secret-tool gnome-keyring-daemon kwalletd6 kwalletd5)"
    echo "keyring=${kr:-none}"
    fu="$(find "$home/.local/share/fonts" "$home/.fonts" -type f 2>/dev/null | wc -l)"
    fs="$(find /usr/local/share/fonts /usr/share/fonts -mindepth 2 -type f 2>/dev/null | wc -l)"
    echo "fonts_user_files=$fu"
    echo "fonts_system_files=$fs"
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
# Catalog-driven: every `dir`/`tar` source root candidate that exists on THIS
# platform shows up here. `>`-separated candidate lists are reported as
# `folder|<first-existing>|candidates=<all>` so the wizard can explain choices.
echo "[folders]"
while IFS=$'\t' read -r _id kind _enabled root _dest _label _extra; do
  [[ -n "$root" && "$kind" != "snapshot" ]] || continue
  found=""
  cands=()
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    cands+=("$cand")
    [[ -z "$found" && -e "$cand" ]] && found="$cand"
  done < <(root_candidates "$root")
  if [[ -n "$found" ]]; then
    echo "folder|$found|candidates=$(join_list "${cands[@]}")"
  else
    echo "folder|absent|candidates=$(join_list "${cands[@]:-}")"
  fi
done < <(render_catalog "$plat")

# --- browsers present ---------------------------------------------------------
echo "[browsers]"
browser_rows "$plat" | while IFS=$'\t' read -r name root _bex; do
  r="$(first_existing_root "$root")"
  if [[ -n "$r" ]]; then
    cands=()
    while IFS= read -r cand; do [[ -n "$cand" ]] && cands+=("$cand"); done < <(root_candidates "$root")
    echo "browser|$name|present|$r|candidates=$(join_list "${cands[@]}")"
  else
    echo "browser|$name|absent|-"
  fi
done

# --- gaming platforms ----------------------------------------------------------
echo "[gaming]"
while IFS=$'\t' read -r gid _kind _enabled root _dest _label _extra; do
  case "$gid" in
    gaming_steam|gaming_libraries|gaming_lutris_data|gaming_heroic_config|gaming_heroic_data|gaming_saves) ;;
    *) continue ;;
  esac
  r="$(first_existing_root "$root")"
  if [[ -n "$r" ]]; then echo "gaming|$gid|present|$r"; else echo "gaming|$gid|absent|-"; fi
done < <(render_catalog "$plat" | awk -F'\t' '$1 ~ /^gaming_/')

# --- virtualization / containers ----------------------------------------------
echo "[virtualization]"
case "$plat" in
  linux|wsl)
    vms="$(virsh list --all --name 2>/dev/null | sed '/^$/d' | wc -l || true)"
    echo "libvirt_vms=$vms"
    if command_present VBoxManage; then
      echo "virtualbox_vms=$(VBoxManage list vms 2>/dev/null | wc -l)"
    else
      echo "virtualbox_vms=0"
    fi
    dc=0; pc=0
    command_present docker && dc="$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l)"
    command_present podman && pc="$(podman ps -a --format '{{.Names}}' 2>/dev/null | wc -l)"
    echo "docker_containers=$dc"
    echo "podman_containers=$pc"
    if [[ "${PROBE_FAST:-0}" == "1" ]]; then
      echo "compose_files=skipped"
      echo "appimages=skipped"
    else
      comp="$(timeout 30 find "$home" -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) ! -path '*/node_modules/*' ! -path '*/.cache/*' 2>/dev/null | wc -l)"
      echo "compose_files=$comp"
      ai="$(timeout 30 find "$home" -iname '*.AppImage' ! -path '*/node_modules/*' ! -path '*/.cache/*' 2>/dev/null | wc -l)"
      echo "appimages=$ai"
    fi
    ;;
  *) echo "n/a" ;;
esac

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

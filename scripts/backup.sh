#!/usr/bin/env bash
# backup-ops: generic backup engine — driven entirely by config/manifest.yml
# (source catalog) + config/user.yml (your selection). No hardcoded paths here.
# Usage:
#   backup.sh                    # back up the active selection to dest
#   backup.sh --dry-run          # preview, no writes
#   backup.sh --preset full      # override preset from user.yml
#   backup.sh --include a,b      # only these source ids
#   backup.sh --exclude a,b      # exclude these source ids
#   backup.sh --ask              # interactive per-source confirmation
#   backup.sh --auto-yes         # non-interactive (default off)
#   backup.sh --root <dir>       # destination override (also useful for drills)
#   backup.sh --force            # bypass free-space gate (explicit)
#
# Cross-distro behavior: migration.yml records the source profile; coverage-report.md
# compares what exists on the machine with what was packed; packages/ carries the
# native/flatpak inventories restore turns into a target install plan.

set -uo pipefail

BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

DRY_RUN=0; PRESET=""; INCLUDE=""; EXCLUDE_LIST=""; ASK=0; ROOT=""; NO_MOUNT_CHECK=0; FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --preset) PRESET="$2"; shift 2 ;;
    --include) INCLUDE="$2"; shift 2 ;;
    --exclude) EXCLUDE_LIST="$2"; shift 2 ;;
    --ask) ASK=1; shift ;;
    --auto-yes) ASK=0; shift ;;
    --root) ROOT="$2"; shift 2 ;;
    --no-mount-check) NO_MOUNT_CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

LOGFILE="$BB_PROJ_DIR/data/run-log.md"
log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOGFILE"; }

plat="$(resolve_platform)"
home="$(expand_home '~')"
DEST="$ROOT"
[[ -z "$DEST" ]] && DEST="$(dest_root)"
[[ -z "$DEST" ]] && { echo "ERROR: no destination (set in config/user.yml \`destination:\` or --root)" >&2; exit 3; }
DEST="$(expand_home "$DEST")"

# --- selection (always normalized to ONE id per line before filtering) --------
if [[ -n "$INCLUDE" ]]; then
  IDS="$(printf '%s' "$INCLUDE" | tr ',' '\n')"
  [[ -n "$PRESET" ]] && IDS="$IDS"$'\n'"$(preset_ids "$PRESET")"
elif [[ -n "$PRESET" ]]; then
  IDS="$(preset_ids "$PRESET")"
else
  IDS="$(active_source_ids)"
fi
if [[ -n "$EXCLUDE_LIST" ]]; then
  for id in $(printf '%s' "$EXCLUDE_LIST" | tr ',' ' '); do
    IDS="$(printf '%s\n' "$IDS" | grep -vx "$id" || true)"
  done
fi

IDS="$(printf '%s\n' "$IDS" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u | tr '\n' ' ')"
[[ -n "$IDS" ]] || { echo "nothing selected (empty active selection)"; exit 0; }
echo "platform=$plat home=$home"
echo "selection: ${IDS}"

MIG_SRC_DISTRO="$(migration_get source.distro auto)"
MIG_SRC_FAMILY="$(migration_get source.family auto)"
MIG_SRC_DE="$(migration_get source.desktop auto)"
[[ "$MIG_SRC_DISTRO" == "auto" || -z "$MIG_SRC_DISTRO" ]] && MIG_SRC_DISTRO="$(distro_id)"
[[ "$MIG_SRC_FAMILY" == "auto" || -z "$MIG_SRC_FAMILY" ]] && MIG_SRC_FAMILY="$(distro_family)"
[[ "$MIG_SRC_DE" == "auto" || -z "$MIG_SRC_DE" ]] && MIG_SRC_DE="$(desktop_name)"
echo "migration: source=${MIG_SRC_DISTRO}/${MIG_SRC_FAMILY}/${MIG_SRC_DE} profile=$(migration_profile)"

# ---------------------------------------------------------------------------
# Size estimate: used by preflight and coverage. Include-only tar sources are
# estimated from their entries, never from the whole home.
# ---------------------------------------------------------------------------
estimate_source_kb() {
  local id="$1" kind root extra r total=0 one val
  kind="$(catalog_field "$id" kind)"
  root="$(catalog_field "$id" root)"
  extra="$(catalog_field "$id" extra)"
  case "$kind" in
    dir)
      r="$(first_existing_root "$root" || true)"
      [[ -n "$r" ]] && total="$(du -sk "$r" 2>/dev/null | awk '{print $1}' || echo 0)"
      ;;
    tar)
      r="$(first_existing_root "$root" || true)"
      if [[ -n "$r" && "$extra" == *include\|* ]]; then
        IFS='|' read -ra _parts <<< "$extra"
        local i
        for ((i=0;i<${#_parts[@]};i+=2)); do
          [[ "${_parts[$i]}" == "include" ]] || continue
          one="${_parts[$((i+1))]}"
          [[ -e "$r/$one" ]] && total=$((total + $(du -sk "$r/$one" 2>/dev/null | awk '{print $1}' || echo 0)))
        done
      elif [[ -n "$r" ]]; then
        total="$(du -sk "$r" 2>/dev/null | awk '{print $1}' || echo 0)"
      fi
      ;;
    drain)
      if [[ "$id" == "browsers" ]]; then
        while IFS=$'\t' read -r _n br _x; do
          r="$(first_existing_root "$br" || true)"
          [[ -n "$r" ]] && total=$((total + $(du -sk "$r" 2>/dev/null | awk '{print $1}' || echo 0)))
        done < <(browser_rows "$plat")
      else
        r="$(first_existing_root "$root" || true)"
        [[ -n "$r" ]] && total="$(du -sk "$r" 2>/dev/null | awk '{print $1}' || echo 0)"
      fi
      ;;
  esac
  printf '%s' "$total"
}

preflight() {
  local est_kb=0 avail_kb min_gb min_pct id
  for id in $IDS; do est_kb=$((est_kb + $(estimate_source_kb "$id"))); done

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN destination: $DEST"
    echo "DRY-RUN estimated payload: $((est_kb / 1024)) MiB"
    return 0
  fi

  mkdir -p "$DEST" || { echo "ERROR: cannot create destination: $DEST" >&2; return 1; }
  if [[ $NO_MOUNT_CHECK -eq 0 ]]; then
    local root_dev dest_dev
    root_dev="$(df -P / 2>/dev/null | tail -1 | awk '{print $1}')"
    dest_dev="$(df -P "$DEST" 2>/dev/null | tail -1 | awk '{print $1}')"
    if [[ -z "$dest_dev" || "$root_dev" == "$dest_dev" ]]; then
      if [[ $FORCE -eq 0 ]]; then
        echo "ERROR: destination '$DEST' not mounted, or same-disk as / (external drive required). Use --force to override." >&2
        return 1
      fi
      echo "WARN: destination is same-disk as / (forced)." >&2
    fi
  fi

  avail_kb="$(df -Pk "$DEST" 2>/dev/null | tail -1 | awk '{print $4}')"
  min_gb="${FREE_MIN_GB:-$(safety_get free_space_min_gb)}"; [[ -n "$min_gb" ]] || min_gb=30
  min_pct="$(safety_get min_free_percent)"; [[ -n "$min_pct" ]] || min_pct=10
  local need_kb=$(( est_kb + (est_kb * min_pct / 100) ))
  if [[ -n "$avail_kb" && "$need_kb" -gt 0 && "$avail_kb" -lt "$need_kb" ]]; then
    if [[ $FORCE -eq 0 ]]; then
      echo "ERROR: estimated payload $((est_kb/1024)) MiB + ${min_pct}% safety > free $((avail_kb/1024)) MiB on '$DEST'. Use --force or free space." >&2
      return 1
    fi
    echo "WARN: free space below estimate (forced)." >&2
  fi
  if [[ -n "$avail_kb" && "$avail_kb" -lt $((min_gb * 1024 * 1024)) ]]; then
    if [[ $FORCE -eq 0 ]]; then
      echo "ERROR: only ~$((avail_kb/1024/1024))GB free on '$DEST' (min ${min_gb}GB). Use --force to override." >&2
      return 1
    fi
    echo "WARN: free space below minimum ${min_gb}GB (forced)." >&2
  fi

  {
    echo "## backup-ops preflight ($(date -Iseconds))"
    echo "destination=$DEST"
    echo "available_kb=${avail_kb:-unknown}"
    echo "estimated_kb=$est_kb"
    echo "minimum_gb=$min_gb"
    echo "minimum_free_percent=$min_pct"
    echo "--- cache/trash sizes (report only; nothing is deleted) ---"
    du -sh "$home/.cache" "$home/.local/share/Trash" "$home/.local/share/Trash/files" 2>/dev/null || true
    echo "--- destination ---"
    df -h "$DEST" 2>/dev/null || true
  } > "$DEST/preflight.txt"
  echo "destination: $DEST"
  echo "estimated payload: $((est_kb / 1024)) MiB"
}

preflight || exit 3

FAILED_SOURCES=()

# --- helpers ------------------------------------------------------------------
rsync_mirror() {
  # rsync_mirror <label> <src> <destrel> [extra-excludes pipe-separated]
  local label="$1" src="$2" rel="$3" bex="${4:-}"
  local -a ex=()
  load_excludes ex
  if [[ -n "$bex" ]]; then
    local -a bx=()
    IFS='|' read -ra bx <<< "$bex"
    local b; for b in "${bx[@]}"; do [[ -n "$b" ]] && ex+=(--exclude="$b"); done
  fi
  local dst="$DEST/$rel"
  [[ $DRY_RUN -eq 0 ]] && mkdir -p "$(dirname "$dst")"
  log "dir  : $label -> $dst"
  if [[ $DRY_RUN -eq 1 ]]; then
    rsync -aAX --dry-run --info=stats1 "${ex[@]}" "$src/" "$dst/" 2>&1 | tail -4
    return 0
  fi
  local fs
  fs="$(findmnt -n -o FSTYPE -T "$dst" 2>/dev/null || echo unknown)"
  if [[ "$fs" =~ (vfat|exfat|ntfs) ]]; then
    rsync -a --no-perms --no-times --chmod=ugo=rwX --info=stats1 "${ex[@]}" "$src/" "$dst/" 2>&1 | tail -4
  else
    rsync -aAX --info=stats1 "${ex[@]}" "$src/" "$dst/" 2>&1 | tail -4
  fi
}

sqlite_drain() {
  local db="$1" staging="$2" rel dst
  rel="${db#$home/}"; dst="$staging/$(printf '%s' "$rel" | tr '/' '_')"
  log "drain: $db -> $dst"
  [[ $DRY_RUN -eq 1 ]] && return 0
  mkdir -p "$staging"
  if ! command -v sqlite3 >/dev/null 2>&1; then echo "WARN: sqlite3 not installed, raw copy" >&2; cp -a "$db" "$dst"; return 0; fi
  sqlite3 "$db" ".backup '$dst'" 2>/dev/null || cp -a "$db" "$dst"
  sqlite3 "$dst" "PRAGMA integrity_check;" 2>/dev/null | grep -q ok || { echo "ERROR: integrity failed: $db" >&2; return 1; }
}

drain_mirror() {
  local name="$1" src="$2" rel="$3" bex="${4:-}"
  [[ -d "$src" ]] || { log "skip : $name missing ($src)"; return 0; }
  local staging="$DEST/.drain/$name"
  [[ $DRY_RUN -eq 0 ]] && mkdir -p "$staging"
  local db
  while IFS= read -r db; do sqlite_drain "$db" "$staging" || return 1; done < <(
    find "$src" \( -name "*.sqlite" -o -name "places.sqlite" -o -name "History" -o -name "Cookies" -o -name "*history*.sqlite" \) \
      ! -path '*/Cache/*' ! -path '*/cache/*' ! -path '*/cache2/*' ! -path '*/startupCache/*' ! -path '*/shader-cache/*' 2>/dev/null)
  rsync_mirror "$name" "$src" "$rel" "$bex"
}

# tar a source honoring include_only/exclude lists from catalog `extra`.
tar_blob() {
  local label="$1" src="$2" rel="$3" extra="$4"
  local -a inc=() exc=()
  local i
  IFS='|' read -ra parts <<< "$extra"
  for ((i=0;i<${#parts[@]};i+=2)); do
    if [[ "${parts[$i]}" == "include" ]]; then
      inc+=("${parts[$((i+1))]}")
    elif [[ "${parts[$i]}" == "exclude" ]]; then
      exc+=(--exclude="${parts[$((i+1))]}")
    fi
  done
  local -a glob=()
  load_excludes glob
  [[ $DRY_RUN -eq 1 ]] && { echo "DRY: tar $label <- $src -> $DEST/$rel.tar.gz (inc:${inc[*]:-all} exc:${#exc[@]})"; return 0; }
  mkdir -p "$(dirname "$DEST/$rel")"
  log "tar  : $label"
  if [[ ${#inc[@]} -gt 0 ]]; then
    local stag="/tmp/backup-ops-${label}-$$"
    rm -rf "$stag"; mkdir -p "$stag"
    local one
    for one in "${inc[@]}"; do
      if [[ -e "$src/$one" ]]; then
        mkdir -p "$(dirname "$stag/$one")"
        cp -a "$src/$one" "$stag/$one"
      fi
    done
    tar "${glob[@]}" --exclude-caches -czf "$DEST/$rel.tar.gz" -C "$stag" . 2>/dev/null \
      && rm -rf "$stag" || { echo "ERROR: tar failed for $label" >&2; rm -rf "$stag"; return 1; }
  else
    tar "${glob[@]}" "${exc[@]}" --exclude-caches -czf "$DEST/$rel.tar.gz" -C "$src" . 2> >(grep -v 'file is the archive' >&2) || { echo "ERROR: tar failed for $label" >&2; return 1; }
  fi
  ( cd "$(dirname "$DEST/$rel.tar.gz")" && sha256sum "$(basename "$DEST/$rel.tar.gz")" > "$(basename "$DEST/$rel.tar.gz").sha256" ) || return 1
}

# --- per-source dispatch ------------------------------------------------------
run_source() {
  local id="$1" kind="$2" root="$3" destrel="$4" label="$5" extra="$6"
  label="${label:-$id}"
  local src
  src="$(first_existing_root "$root" || true)"
  if [[ -z "$src" ]]; then
    log "skip : $label missing ($root)"
    return 0
  fi
  # Report but do not copy alternates (native + flatpak both installed).
  local cand
  while IFS= read -r cand; do
    [[ -n "$cand" && "$cand" != "$src" && -e "$cand" ]] && log "note : $label alternate root present: $cand"
  done < <(root_candidates "$root")

  if [[ $ASK -eq 1 ]]; then
    printf 'Include %s? [Y/n] ' "$label"
    read -r ans
    case "${ans:-Y}" in [nN]) echo "  skipped: $label"; return 0 ;; esac
  fi

  case "$kind" in
    dir)  rsync_mirror "$id" "$src" "$destrel" ;;
    drain) drain_mirror "$id" "$src" "$destrel" ;;
    tar)  tar_blob "$id" "$src" "$destrel" "$extra" ;;
  esac
}

run_browsers() {
  local destrel="$1" name root bex r rc=0
  while IFS=$'\t' read -r name root bex; do
    r="$(first_existing_root "$root" || true)"
    if [[ -z "$r" ]]; then
      log "skip browser: $name missing ($root)"
      continue
    fi
    local cand
    while IFS= read -r cand; do
      [[ -n "$cand" && "$cand" != "$r" && -e "$cand" ]] && log "note browser: $name alternate root present: $cand"
    done < <(root_candidates "$root")
    drain_mirror "$name" "$r" "$destrel/$name" "$bex" || rc=1
  done < <(browser_rows "$plat")
  return $rc
}

# --- snapshot collectors -----------------------------------------------------
capture() { # capture <file> <cmd...>
  local out="$1"; shift
  { "$@" 2>/dev/null || echo "skipped-failed: $*"; } > "$out"
}

copy_path() { # copy_path <outdir> <name> <source>
  local out="$1" name="$2" src="$3" status
  mkdir -p "$out"
  if [[ ! -e "$src" ]]; then
    printf '%s\tskipped-missing\t%s\n' "$src" "$name" >> "$out/manifest.tsv"
    return 0
  fi
  if cp -a "$src" "$out/$name" 2>/dev/null; then
    status="ok"
  elif sudo -n cp -a "$src" "$out/$name" 2>/dev/null; then
    status="ok-sudo"
  else
    status="skipped-permission"
  fi
  printf '%s\t%s\t%s\n' "$src" "$status" "$name" >> "$out/manifest.tsv"
}

filter_pkg_list() {
  local in="$1" out="$2"
  # Anchored filters avoid the gist's false positives: `libreoffice`, `calibre`
  # and similar apps must survive a `lib` filter.
  grep -vE '^(lib|gir1|gstreamer|python3?-|perl-|ruby-|node-|npm-|rust-|golang-|java-|fc-|xorg-|mesa-|systemd-|glibc|gcc-|binutils|linux-|linux-firmware|qt[0-9]?-|fonts?-|font-)([:_-]|$)|.*-(dev|dbg|doc|locale|i18n)$' "$in" > "$out" || true
}

snapshot_packages() {
  local out="$DEST/$1" pm
  mkdir -p "$out"
  pm="$(pkg_manager)"
  {
    echo "# Package inventory — $(date -Iseconds)"
    echo "platform=$plat"
    echo "distro=$(distro_id)"
    echo "family=$(distro_family)"
    echo "package_manager=$pm"
    echo
    echo "This is the source inventory. Restore generates a target-family install"
    echo "plan; package names may differ across families and need review."
  } > "$out/README.md"

  case "$pm" in
    apt)
      apt-mark showmanual 2>/dev/null | sort -u > "$out/native-explicit.txt"
      dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort > "$out/native-full.tsv"
      cut -f1 "$out/native-full.tsv" > "$out/native-full.txt"
      ;;
    pacman)
      pacman -Qqe 2>/dev/null | sort -u > "$out/native-explicit.txt"
      pacman -Qqem 2>/dev/null | sort -u > "$out/aur-explicit.txt"
      pacman -Q 2>/dev/null | sort > "$out/native-full.tsv"
      cut -d' ' -f1 "$out/native-full.tsv" > "$out/native-full.txt"
      ;;
    dnf)
      dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null | sort -u > "$out/native-explicit.txt"
      if [[ ! -s "$out/native-explicit.txt" ]]; then
        dnf history userinstalled 2>/dev/null | sed '/^$/d;/^User/d;/^Package/d' | awk '{print $1}' | sort -u > "$out/native-explicit.txt"
      fi
      rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort > "$out/native-full.tsv"
      cut -f1 "$out/native-full.tsv" > "$out/native-full.txt"
      ;;
    zypper)
      rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort > "$out/native-full.tsv"
      cut -f1 "$out/native-full.tsv" > "$out/native-full.txt"
      zypper --non-interactive search -i -t package 2>/dev/null | awk 'NR>4 && $2=="|" {print $3}' | sort -u > "$out/native-explicit.txt"
      ;;
    *)
      : > "$out/native-explicit.txt"
      : > "$out/native-full.tsv"
      : > "$out/native-full.txt"
      echo "skipped: no supported native package manager" >> "$out/README.md"
      ;;
  esac

  if command_present flatpak; then
    flatpak list --app --columns=application,version,branch,origin 2>/dev/null | sort > "$out/flatpak.tsv"
    cut -f1 "$out/flatpak.tsv" > "$out/flatpak.txt"
  else
    : > "$out/flatpak.tsv"; : > "$out/flatpak.txt"
  fi
  if command_present snap; then
    snap list 2>/dev/null | awk 'NR>1 {print $1}' | sort -u > "$out/snap.txt"
  else
    : > "$out/snap.txt"
  fi

  [[ -s "$out/native-explicit.txt" ]] && filter_pkg_list "$out/native-explicit.txt" "$out/native-apps.txt"
  [[ -s "$out/aur-explicit.txt" ]] && filter_pkg_list "$out/aur-explicit.txt" "$out/aur-apps.txt"

  {
    echo "native_explicit=$(wc -l < "$out/native-explicit.txt" 2>/dev/null || echo 0)"
    echo "native_apps=$(wc -l < "$out/native-apps.txt" 2>/dev/null || echo 0)"
    echo "native_full=$(wc -l < "$out/native-full.txt" 2>/dev/null || echo 0)"
    echo "flatpak=$(wc -l < "$out/flatpak.txt" 2>/dev/null || echo 0)"
    echo "snap=$(wc -l < "$out/snap.txt" 2>/dev/null || echo 0)"
  } > "$out/counts.txt"

  {
    echo "# Suggested install command on the TARGET family"
    echo "# Review native-apps.txt first; names are not translated automatically."
    case "$(pkg_manager)" in
      apt) echo "sudo apt install -y \$(cat native-apps.txt)" ;;
      pacman) echo "sudo pacman -S --needed - < native-apps.txt" ;;
      dnf) echo "sudo dnf install -y \$(cat native-apps.txt)" ;;
      zypper) echo "sudo zypper install -y \$(cat native-apps.txt)" ;;
      *) echo "# (target package manager not detected on this host)" ;;
    esac
    echo
    echo "# Flatpak apps (portable across distros):"
    echo "flatpak install flathub \$(cat flatpak.txt)"
  } > "$out/install-hints.txt"
}

snapshot_system() {
  local out="$DEST/$1"
  mkdir -p "$out"
  {
    echo "# System state — $(date -Iseconds)"
    echo
    echo "Informational. Restore never applies this automatically."
    echo "Use it as the reinstall checklist: packages, fstab, mounts, cron, timers, units."
  } > "$out/README.md"
  {
    echo "## system-state snapshot ($(date -Is))"
    echo "platform=$plat"
    echo "os_release=$(os_release_field PRETTY_NAME)"
    echo "os_id=$(distro_id)"
    echo "family=$(distro_family)"
    echo "desktop=$(desktop_name)"
    echo "package_manager=$(pkg_manager)"
    echo "--- dpkg/apt packages (first 300) ---"
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | head -300
    echo "--- flatpak apps ---"
    flatpak list --app --columns=application 2>/dev/null || true
    echo "--- fstab ---"
    cat /etc/fstab 2>/dev/null
    echo "--- systemd user units ---"
    systemctl --user list-unit-files --no-pager 2>/dev/null | head -40
  } > "$out/snapshot.txt" 2>/dev/null

  cat /etc/os-release > "$out/os-release.txt" 2>/dev/null || echo "skipped-missing" > "$out/os-release.txt"
  cat /etc/fstab > "$out/fstab.txt" 2>/dev/null || echo "skipped-missing" > "$out/fstab.txt"
  uname -a > "$out/kernel.txt" 2>/dev/null || true
  findmnt -rn > "$out/mounts.txt" 2>/dev/null || echo "skipped-failed" > "$out/mounts.txt"
  lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT > "$out/lsblk.txt" 2>/dev/null || echo "skipped-failed" > "$out/lsblk.txt"
  crontab -l > "$out/crontab-user.txt" 2>/dev/null || echo "skipped-missing" > "$out/crontab-user.txt"
  if sudo -n true 2>/dev/null; then
    sudo -n crontab -l > "$out/crontab-root.txt" 2>/dev/null || echo "empty" > "$out/crontab-root.txt"
  else
    echo "skipped-permission (run: sudo crontab -l)" > "$out/crontab-root.txt"
  fi
  systemctl --user list-timers --all --no-pager > "$out/timers-user.txt" 2>/dev/null || echo "skipped-failed" > "$out/timers-user.txt"
  systemctl list-timers --all --no-pager > "$out/timers-system.txt" 2>/dev/null || echo "skipped-failed" > "$out/timers-system.txt"
  systemctl --user list-unit-files --no-pager > "$out/units-user.txt" 2>/dev/null || echo "skipped-failed" > "$out/units-user.txt"
  systemctl list-unit-files --state=enabled --no-pager > "$out/units-enabled.txt" 2>/dev/null || echo "skipped-failed" > "$out/units-enabled.txt"
  timedatectl 2>/dev/null > "$out/time.txt" || true
  locale 2>/dev/null > "$out/locale.txt" || true
}

snapshot_system_files() {
  local out="$DEST/$1" f
  mkdir -p "$out"
  : > "$out/manifest.tsv"
  copy_path "$out" "etc-fstab" "/etc/fstab"
  copy_path "$out" "etc-hosts" "/etc/hosts"
  copy_path "$out" "etc-hostname" "/etc/hostname"
  copy_path "$out" "etc-locale.conf" "/etc/locale.conf"
  copy_path "$out" "etc-vconsole.conf" "/etc/vconsole.conf"
  copy_path "$out" "etc-default-grub" "/etc/default/grub"
  copy_path "$out" "ssh-sshd_config" "/etc/ssh/sshd_config"
  for f in /etc/ssh/ssh_host_*; do
    [[ -e "$f" ]] || continue
    copy_path "$out" "ssh-$(basename "$f")" "$f"
  done
  copy_path "$out" "udev-rules" "/etc/udev/rules.d"
  copy_path "$out" "sysctl-d" "/etc/sysctl.d"
  copy_path "$out" "cron-d" "/etc/cron.d"
  copy_path "$out" "cron-daily" "/etc/cron.daily"
  copy_path "$out" "systemd-system" "/etc/systemd/system"
  copy_path "$out" "modprobe-d" "/etc/modprobe.d"
  copy_path "$out" "security-limits-d" "/etc/security/limits.d"

  if sudo -n true 2>/dev/null; then
    sudo -n chown -R "$(id -u):$(id -g)" "$out" 2>/dev/null || true
  fi
  find "$out" -name 'ssh-ssh_host_*' -type f -exec chmod 600 {} + 2>/dev/null || true

  {
    echo "# System files — manual restore only"
    echo "Generated: $(date -Iseconds)"
    echo
    echo "These files were copied for review. restore.sh NEVER writes /etc."
    echo "Apply only the entries you need, after comparing with the target distro:"
    echo "  fstab, hosts, sshd_config, udev rules, sysctl, cron, systemd units."
    echo
    echo "Status counts:"
    awk -F'\t' '{c[$2]++} END {for (k in c) print k": "c[k]}' "$out/manifest.tsv" 2>/dev/null
  } > "$out/README.md"
}

snapshot_network() {
  local out="$DEST/$1"
  mkdir -p "$out"
  : > "$out/manifest.tsv"
  capture "$out/nmcli-connections.txt" nmcli connection show
  copy_path "$out" "NetworkManager.conf" "/etc/NetworkManager/NetworkManager.conf"
  copy_path "$out" "system-connections" "/etc/NetworkManager/system-connections"
  copy_path "$out" "conf.d" "/etc/NetworkManager/conf.d"
  copy_path "$out" "dispatcher.d" "/etc/NetworkManager/dispatcher.d"
  copy_path "$out" "systemd-network" "/etc/systemd/network"
  copy_path "$out" "netplan" "/etc/netplan"
  copy_path "$out" "wpa_supplicant" "/etc/wpa_supplicant"
  if sudo -n true 2>/dev/null; then
    sudo -n chown -R "$(id -u):$(id -g)" "$out" 2>/dev/null || true
  fi
  {
    echo "# Network state — manual restore only"
    echo "Generated: $(date -Iseconds)"
    echo
    echo "NetworkManager system-connections contain WiFi/VPN secrets. This"
    echo "directory is chmod 600. restore.sh stages it; never auto-applies."
    echo "Review nmcli-connections.txt and the copied profiles on the target."
  } > "$out/README.md"
  find "$out" -type f -exec chmod 600 {} + 2>/dev/null || true
}

snapshot_virtualization() {
  local out="$DEST/$1" vm net vms_file
  mkdir -p "$out/vms_xml" "$out/networks_xml"
  : > "$out/README.md"
  {
    echo "# Virtualization inventory — $(date -Iseconds)"
    echo "Power off VMs before copying disks. Definitions are safe to export."
    echo
  } >> "$out/README.md"

  if command_present virsh; then
    vms_file="$out/virsh-list.txt"
    { virsh list --all 2>/dev/null || sudo -n virsh list --all 2>/dev/null || echo "skipped-permission"; } > "$vms_file"
    { virsh net-list --all 2>/dev/null || sudo -n virsh net-list --all 2>/dev/null || echo "skipped-permission"; } > "$out/virsh-net-list.txt"
    while IFS= read -r vm; do
      [[ -n "$vm" ]] || continue
      if virsh dumpxml "$vm" > "$out/vms_xml/${vm}.xml" 2>/dev/null || sudo -n virsh dumpxml "$vm" > "$out/vms_xml/${vm}.xml" 2>/dev/null; then
        echo "exported VM XML: $vm" >> "$out/README.md"
      else
        echo "failed VM XML: $vm (permission?)" >> "$out/README.md"
      fi
    done < <( { virsh list --all --name 2>/dev/null || sudo -n virsh list --all --name 2>/dev/null; } | sed '/^$/d')
    while IFS= read -r net; do
      [[ -n "$net" ]] || continue
      if virsh net-dumpxml "$net" > "$out/networks_xml/${net}.xml" 2>/dev/null || sudo -n virsh net-dumpxml "$net" > "$out/networks_xml/${net}.xml" 2>/dev/null; then
        echo "exported network XML: $net" >> "$out/README.md"
      fi
    done < <( { virsh net-list --all --name 2>/dev/null || sudo -n virsh net-list --all --name 2>/dev/null; } | sed '/^$/d')
    { du -sh /var/lib/libvirt/images 2>/dev/null || sudo -n du -sh /var/lib/libvirt/images 2>/dev/null || echo "disk usage unavailable"; } > "$out/libvirt-images-size.txt"
  else
    echo "virsh not installed on source" > "$out/virsh-list.txt"
  fi

  if command_present VBoxManage; then
    VBoxManage list vms 2>/dev/null > "$out/virtualbox-vms.txt"
    VBoxManage list runningvms 2>/dev/null > "$out/virtualbox-running.txt"
    echo "VirtualBox inventory captured." >> "$out/README.md"
  else
    echo "VBoxManage not installed on source" > "$out/virtualbox-vms.txt"
  fi

  if migration_bool include_vm_disks false; then
    echo "Disk images NOT copied (migration.include_vm_disks=false)." > "$out/disks-skipped.txt"
  elif command_present virsh && sudo -n true 2>/dev/null; then
    mkdir -p "$out/disks"
    if sudo -n rsync -a --sparse /var/lib/libvirt/images/ "$out/disks/" 2>/dev/null; then
      sudo -n chown -R "$(id -u):$(id -g)" "$out/disks" 2>/dev/null || true
      echo "Disk images copied with --sparse." > "$out/disks/README.md"
    else
      echo "Disk copy failed (VMs running or permission)." > "$out/disks/README.md"
    fi
  else
    echo "Disk copy skipped: no sudo/virsh, or include_vm_disks=false." > "$out/disks-skipped.txt"
  fi
}

snapshot_containers() {
  local out="$DEST/$1" f rel
  mkdir -p "$out/compose-files"
  {
    echo "# Containers — $(date -Iseconds)"
    echo "Inventory only; volumes are NOT dumped automatically."
  } > "$out/README.md"
  if command_present docker; then
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Mounts}}' > "$out/docker-containers.txt" 2>/dev/null || sudo -n docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Mounts}}' > "$out/docker-containers.txt" 2>/dev/null || echo "skipped-permission" > "$out/docker-containers.txt"
    docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' > "$out/docker-images.txt" 2>/dev/null || true
    docker volume ls -q > "$out/docker-volumes.txt" 2>/dev/null || true
  fi
  if command_present podman; then
    podman ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Mounts}}' > "$out/podman-containers.txt" 2>/dev/null || true
    podman images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' > "$out/podman-images.txt" 2>/dev/null || true
    podman volume ls -q > "$out/podman-volumes.txt" 2>/dev/null || true
  fi

  : > "$out/compose-files.txt"
  while IFS= read -r -d '' f; do
    rel="${f#$home/}"
    mkdir -p "$out/compose-files/$(dirname "$rel")"
    cp -p "$f" "$out/compose-files/$rel" 2>/dev/null && printf '%s\n' "$f" >> "$out/compose-files.txt"
  done < <(timeout 60 find "$home" -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) ! -path '*/node_modules/*' ! -path '*/.cache/*' ! -path "$DEST/*" -print0 2>/dev/null)

  {
    echo "#!/usr/bin/env bash"
    echo "# Generated by backup-ops. Review before running. Dumps named volumes."
    echo "set -euo pipefail"
    echo "OUT=\"\${1:-$out/volumes}\""
    echo "mkdir -p \"\$OUT\""
    echo "# Docker:"
    if command_present docker; then
      while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        printf 'docker run --rm -v %q:/data -v "$OUT":/backup alpine tar -czf "/backup/%s.tar.gz" -C /data .\n' "$vol" "$vol"
      done < <(docker volume ls -q 2>/dev/null || true)
    fi
    echo "# Podman:"
    if command_present podman; then
      while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        printf 'podman run --rm -v %q:/data -v "$OUT":/backup alpine tar -czf "/backup/%s.tar.gz" -C /data .\n' "$vol" "$vol"
      done < <(podman volume ls -q 2>/dev/null || true)
    fi
  } > "$out/backup-volumes.sh"
  chmod +x "$out/backup-volumes.sh" 2>/dev/null || true
}

snapshot_audit() {
  local out="$DEST/$1" timeout_s raw
  mkdir -p "$out"
  timeout_s="$(safety_get stray_timeout_seconds)"; [[ -n "$timeout_s" ]] || timeout_s=120
  raw="$out/stray-files.raw"
  timeout "$timeout_s" find / \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp \
       -o -path /media -o -path /mnt -o -path /timeshift \
       -o -path "$home" -o -path "$DEST" \) -prune \
    -o -uid "$(id -u)" -print0 2>/dev/null > "$raw" || echo "timeout-or-partial" > "$out/status.txt"
  tr '\0' '\n' < "$raw" | sort -u > "$out/stray-files.txt"
  xargs -0 -r -n1 dirname < "$raw" 2>/dev/null | sort -u > "$out/stray-parents.txt"
  {
    echo "# Stray-file audit — report only"
    echo "Generated: $(date -Iseconds)"
    echo "Files outside \$HOME owned by uid $(id -u). Nothing was copied."
    echo "Review stray-parents.txt first."
  } > "$out/README.md"
}

scan_appimages() {
  local out="$DEST/$1" timeout_s src rel dest sha mode
  mkdir -p "$out/files"
  : > "$out/appimages.tsv"
  timeout_s="$(safety_get appimage_timeout_seconds)"; [[ -n "$timeout_s" ]] || timeout_s=120
  while IFS= read -r -d '' src; do
    rel="${src#/}"
    dest="$out/files/$rel"
    mkdir -p "$(dirname "$dest")"
    if cp -p "$src" "$dest" 2>/dev/null || sudo -n cp -p "$src" "$dest" 2>/dev/null; then
      chmod +x "$dest" 2>/dev/null || true
      sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
      mode="$(stat -c %a "$dest" 2>/dev/null || echo unknown)"
      printf '%s\t%s\t%s\t%s\n' "$src" "files/$rel" "$sha" "$mode" >> "$out/appimages.tsv"
    fi
  done < <(timeout "$timeout_s" find "$home" /opt /usr/local /usr/bin /usr/share \
    \( -path "$DEST" -o -path '*/node_modules' -o -path '*/.cache' \) -prune -o \
    -iname '*.AppImage' -print0 2>/dev/null)
  if sudo -n true 2>/dev/null; then
    sudo -n chown -R "$(id -u):$(id -g)" "$out/files" 2>/dev/null || true
  fi
  {
    echo "# AppImages — scan + copy"
    echo "Generated: $(date -Iseconds)"
    echo "Copied $(wc -l < "$out/appimages.tsv" 2>/dev/null || echo 0) AppImages."
    echo "appimages.tsv: original path, relative copy, sha256, mode."
    echo "Restore: copy the relative files you need to ~/AppImages/ and chmod +x."
  } > "$out/README.md"
}

snapshot_saves() {
  local out="$DEST/$1"
  mkdir -p "$out"
  {
    echo "# Save games — $(date -Iseconds)"
    echo
  } > "$out/README.md"
  {
    echo "steam_userdata=$(first_existing_root "$home/.local/share/Steam/userdata > $home/.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata" || true)"
    echo "steam_compatdata=$(first_existing_root "$home/.local/share/Steam/steamapps/compatdata > $home/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata" || true)"
    echo "lutris=$(first_existing_root "$home/.local/share/lutris > $home/.var/app/net.lutris.Lutris/data/lutris" || true)"
    echo "heroic=$(first_existing_root "$home/.config/heroic > $home/.var/app/com.heroicgameslauncher.hgl/config/heroic" || true)"
    echo "games=$(first_existing_root "$home/Games" || true)"
  } > "$out/detected-roots.txt"

  if command_present ludusavi; then
    ludusavi --version > "$out/ludusavi-version.txt" 2>/dev/null || true
    if timeout 300 ludusavi backup --path "$out/ludusavi" --force > "$out/ludusavi.log" 2>&1; then
      echo "Ludusavi backup completed." >> "$out/README.md"
    else
      echo "Ludusavi backup failed; see ludusavi.log. Use its GUI/CLI on the source." >> "$out/README.md"
    fi
  else
    {
      echo "Ludusavi not installed. Install it on the SOURCE and retry:"
      echo "  flatpak install flathub com.github.mtkennerly.ludusavi"
      echo "  ludusavi backup --path '$out/ludusavi' --force"
      echo "Steam/Lutris/Heroic data directories are separately selectable sources."
    } >> "$out/README.md"
  fi
}

snapshot_toolchains() {
  local out="$DEST/$1" root="$2" d
  mkdir -p "$out"
  {
    echo "## toolchain dirs ($(date -Is)) — informational, re-installed not restored"
    printf '%s' "$root" | tr '>' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | while IFS= read -r d; do
      [[ -n "$d" ]] && du -sh "$(expand_home "$d")" 2>/dev/null || true
    done
  } > "$out/toolchains.txt" 2>/dev/null
}

run_snapshot() {
  local id="$1" destrel="$2" root="$3"
  if [[ $DRY_RUN -eq 1 ]]; then echo "DRY: snapshot $id -> $DEST/$destrel"; return 0; fi
  mkdir -p "$DEST/$destrel"
  log "snap : $id"
  case "$id" in
    packages) snapshot_packages "$destrel" ;;
    snapshots) snapshot_system "$destrel" ;;
    system_files) snapshot_system_files "$destrel" ;;
    network) snapshot_network "$destrel" ;;
    virtualization) snapshot_virtualization "$destrel" ;;
    containers) snapshot_containers "$destrel" ;;
    audit) snapshot_audit "$destrel" ;;
    appimages) scan_appimages "$destrel" ;;
    gaming_saves) snapshot_saves "$destrel" ;;
    toolchains) snapshot_toolchains "$destrel" "$root" ;;
    *)
      {
        echo "## system-state snapshot ($(date -Is))"
        echo "platform=$plat"
        echo "os_release=$(os_release_field PRETTY_NAME)"
        echo "--- packages ---"
        dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | head -300
        echo "--- flatpak apps ---"
        flatpak list --app --columns=application 2>/dev/null || true
        echo "--- fstab ---"
        cat /etc/fstab 2>/dev/null
        echo "--- systemd user units ---"
        systemctl --user list-unit-files --no-pager 2>/dev/null | head -40
      } > "$DEST/$destrel/snapshot.txt" 2>/dev/null
      ;;
  esac
}

# --- coverage report ---------------------------------------------------------
GAPS=()
count_lines() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
count_files() { [[ -d "$1" ]] && find "$1" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0; }

detected_browsers() {
  local n=0 name root r
  while IFS=$'\t' read -r name root _bex; do
    r="$(first_existing_root "$root" || true)"
    [[ -n "$r" ]] && n=$((n+1))
  done < <(browser_rows "$plat")
  echo "$n"
}

coverage_report() {
  local browsers_detected browsers_backed appimgs packages_n flatpak_n fonts_n vms_n compose_n stray_n
  local pkg_pm
  browsers_detected="$(detected_browsers)"
  browsers_backed="$(find "$DEST/browsers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  appimgs="$(count_lines "$DEST/portable/appimages/appimages.tsv")"
  packages_n="$(count_lines "$DEST/packages/native-explicit.txt")"
  flatpak_n="$(count_lines "$DEST/packages/flatpak.txt")"
  fonts_n="$(count_files "$DEST/fonts/user")"
  vms_n="$(grep -vE '^(Name|Id|-----|virsh not installed|skipped|$)' "$DEST/virtualization/virsh-list.txt" 2>/dev/null | wc -l | tr -d ' ' || true)"
  [[ -n "$vms_n" ]] || vms_n=0
  compose_n="$(count_lines "$DEST/containers/compose-files.txt")"
  stray_n="$(count_lines "$DEST/audit/stray-files.txt")"
  pkg_pm="$(pkg_manager)"

  if [[ " $IDS " == *" browsers "* && "$browsers_detected" -gt 0 && "$browsers_backed" -eq 0 ]]; then
    GAPS+=("browsers: $browsers_detected detected, 0 backed up")
  fi
  if [[ " $IDS " == *" packages "* && -n "$pkg_pm" && "$packages_n" -eq 0 ]]; then
    GAPS+=("packages: $pkg_pm present but native-explicit.txt is empty")
  fi
  if [[ " $IDS " == *" gaming_steam "* && -n "$(first_existing_root "$(catalog_field gaming_steam root)" || true)" && ! -d "$DEST/gaming/steam" ]]; then
    GAPS+=("gaming_steam: Steam library present but not backed up")
  fi
  if [[ " $IDS " == *" system_files "* && ! -s "$DEST/system-files/manifest.tsv" ]]; then
    GAPS+=("system_files: no manifest produced")
  fi

  {
    echo "# Backup coverage report"
    echo
    echo "Generated: $(date -Iseconds)"
    echo "Source: \`${MIG_SRC_DISTRO}/${MIG_SRC_FAMILY}/${MIG_SRC_DE}\`"
    echo "Target: \`$(migration_get target.distro unknown)/$(migration_get target.family unknown)/$(migration_get target.desktop unknown)\`"
    echo "Profile: \`$(migration_profile)\`"
    echo
    echo "| Item | Detected | Backed up | Status |"
    echo "|---|---:|---:|---|"
    echo "| Browsers | $browsers_detected | $browsers_backed | $([[ "$browsers_detected" -gt "$browsers_backed" ]] && echo GAP || echo OK) |"
    echo "| Native packages (explicit) | - | $packages_n | $([[ "$packages_n" -eq 0 && -n "$pkg_pm" ]] && echo GAP || echo OK) |"
    echo "| Flatpak apps | - | $flatpak_n | OK |"
    echo "| AppImages | - | $appimgs | OK |"
    echo "| User fonts | - | $fonts_n files | OK |"
    echo "| VMs (virsh list lines) | - | ${vms_n:-0} | OK |"
    echo "| Compose files | - | $compose_n | OK |"
    echo "| Stray files outside home | - | $stray_n | report |"
    echo
    echo "## Notes"
    echo "- Packages are the source inventory; restore generates the target plan."
    echo "- Browsers restore data profiles only; Chromium passwords need the keyring."
    echo "- DE configs are backed up separately and gated by restore_policy: same-de."
    echo "- System/network/VM/container data is manual-restore only."
    if [[ ${#GAPS[@]} -gt 0 ]]; then
      echo
      echo "## CRITICAL GAPS"
      printf -- '- %s\n' "${GAPS[@]}"
    else
      echo
      echo "No critical gaps detected. Review the table and preflight.txt."
    fi
  } > "$DEST/coverage-report.md"
}

write_backup_info() {
  local gaps="${#GAPS[@]}"
  {
    echo "# backup-ops backup info — generated $(date -Iseconds)"
    echo "schema: 1"
    echo "created: \"$(date -Iseconds)\""
    echo "host: \"$(hostname 2>/dev/null)\""
    echo "uid: \"$(id -u)\""
    echo "platform: \"$plat\""
    echo "source_distro: \"$MIG_SRC_DISTRO\""
    echo "source_family: \"$MIG_SRC_FAMILY\""
    echo "source_desktop: \"$MIG_SRC_DE\""
    echo "selection: \"$IDS\""
    echo "catalog_sha256: \"$(sha256sum "$BB_CATALOG" 2>/dev/null | awk '{print $1}')\""
    echo "backup_ops_version: \"1.1\""
    echo "critical_gaps: $gaps"
  } > "$DEST/backup-info.yml"
}

write_manifest() {
  ( cd "$DEST" && find . -type f ! -name manifest.sha256 -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum > manifest.sha256 )
}

# ===========================================================================
log "backup start (platform=$plat, selection: $IDS)"
for id in $IDS; do
  line="$(render_catalog "$plat" | awk -F'\t' -v id="$id" '$1==id{print; exit}')"
  [[ -z "$line" ]] && { log "skip : unknown source id $id"; continue; }
  kind="$(printf '%s' "$line" | cut -f2)"
  root="$(printf '%s' "$line" | cut -f4)"
  destrel="$(printf '%s' "$line" | cut -f5)"
  label="$(printf '%s' "$line" | cut -f6)"
  extra="$(printf '%s' "$line" | cut -f7)"
  if [[ "$id" == "browsers" ]]; then
    run_browsers "$destrel" || { log "FAIL : browsers"; FAILED_SOURCES+=("browsers"); }
    continue
  fi
  if [[ "$kind" == "snapshot" ]]; then
    run_snapshot "$id" "$destrel" "$root" || { log "FAIL : $id"; FAILED_SOURCES+=("$id"); }
    continue
  fi
  run_source "$id" "$kind" "$root" "$destrel" "$label" "$extra" || { log "FAIL : $id"; FAILED_SOURCES+=("$id"); }
done

if [[ $DRY_RUN -eq 1 ]]; then echo "DRY-RUN complete"; exit 0; fi

for _failed in "${FAILED_SOURCES[@]:-}"; do
  [[ -n "$_failed" ]] && GAPS+=("source failed: $_failed")
done

write_migration_manifest "$DEST" "$IDS" "$plat"
coverage_report
write_backup_info
cp -a "$BB_CATALOG" "$DEST/manifest.yml" 2>/dev/null || true
[[ -f "$BB_USER" ]] && cp -a "$BB_USER" "$DEST/user.yml" 2>/dev/null || true
write_manifest

echo "backup finished -> $DEST"
echo "  coverage: $DEST/coverage-report.md"
echo "  packages: $DEST/packages/"
if [[ ${#GAPS[@]} -gt 0 ]]; then
  echo "CRITICAL COVERAGE GAPS:" >&2
  printf '  - %s\n' "${GAPS[@]}" >&2
  exit 4
fi
exit 0

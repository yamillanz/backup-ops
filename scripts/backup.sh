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
#   backup.sh --auto-yes         # non-interactive (default off; set in user.yml)

set -uo pipefail

BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

DRY_RUN=0; PRESET=""; INCLUDE=""; EXCLUDE_LIST=""; ASK=0; ROOT=""; NO_MOUNT_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --preset) PRESET="$2"; shift 2 ;;
    --include) INCLUDE="$2"; shift 2 ;;
    --exclude) EXCLUDE_LIST="$2"; shift 2 ;;
    --ask) ASK=1; shift ;;
    --root) ROOT="$2"; shift 2 ;;
    --no-mount-check) NO_MOUNT_CHECK=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

LOG="$(printf '%s' "$ROOT")"   # keep var; real log below
LOGFILE="$BB_PROJ_DIR/data/run-log.md"
log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOGFILE"; }

plat="$(resolve_platform)"
home="$(expand_home '~')"
DEST="$ROOT"
[[ -z "$DEST" ]] && DEST="$(dest_root)"
[[ -z "$DEST" ]] && { echo "ERROR: no destination (set in config/user.yml `destination:` or --root)" >&2; exit 3; }
DEST="$(expand_home "$DEST")"

# --- selection ---------------------------------------------------------------
if [[ -n "$INCLUDE" ]]; then
  # --include defines the run entirely (restrictive)
  IDS="$(printf '%s' "$INCLUDE" | tr ',' ' ')"
  [[ -n "$PRESET" ]] && IDS="$IDS $(preset_ids "$PRESET" | tr '\n' ' ')"
elif [[ -n "$PRESET" ]]; then
  # temporary override: honor preset for this run only
  IDS="$(preset_ids "$PRESET" | tr '\n' ' ')"
else
  IDS="$(active_source_ids)"
fi
if [[ -n "$EXCLUDE_LIST" ]]; then
  for id in $(printf '%s' "$EXCLUDE_LIST" | tr ',' ' '); do
    IDS="$(printf '%s\n' "$IDS" | grep -vx "$id" || true)"
  done
fi

IDS="$(printf '%s\n' "$IDS" | sed '/^[[:space:]]*$/d' | sort -u | tr '\n' ' ')"
[[ -n "$IDS" ]] || { echo "nothing selected (empty active selection)"; exit 0; }
echo "platform=$plat home=$home"
echo "selection: ${IDS}"

# --- mount safety -------------------------------------------------------------
if [[ $DRY_RUN -eq 0 && $NO_MOUNT_CHECK -eq 0 ]]; then
  mkdir -p "$DEST"
  root_dev="$(df -P / 2>/dev/null | tail -1 | awk '{print $1}')"
  dest_dev="$(df -P "$DEST" 2>/dev/null | tail -1 | awk '{print $1}')"
  if [[ -z "$dest_dev" || "$root_dev" == "$dest_dev" ]]; then
    echo "ERROR: destination '$DEST' not mounted, or same-disk as / (external drive required)." >&2
    exit 3
  fi
  free_gb="$(df -P "$DEST" 2>/dev/null | tail -1 | awk '{print $4}')"
  min_gb="${FREE_MIN_GB:-30}"
  if [[ -n "$free_gb" && "$free_gb" -lt $((min_gb * 1024 * 1024)) ]]; then
    echo "WARN: only ~$((free_gb / 1024 / 1024))GB free on '$DEST' (min ${min_gb}GB). Continuing anyway; you can abort with Ctrl-C." >&2
  fi
  echo "destination: $DEST"
else
  echo "DRY-RUN destination: $DEST"
fi

# --- helpers ------------------------------------------------------------------
expand_src() { expand_home "$1"; }

rsync_mirror() {
  # rsync_mirror <label> <src> <destrel>
  local label="$1" src="$2" rel="$3"
  local -a ex=()
  load_excludes ex
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
  rel="${db#$home/}"; mkdir -p "$staging"
  dst="$staging/$(printf '%s' "$rel" | tr '/' '_')"
  log "drain: $db -> $dst"
  [[ $DRY_RUN -eq 1 ]] && return 0
  if ! command -v sqlite3 >/dev/null 2>&1; then echo "WARN: sqlite3 not installed, raw copy" >&2; cp -a "$db" "$dst"; return 0; fi
  sqlite3 "$db" ".backup '$dst'" 2>/dev/null || cp -a "$db" "$dst"
  sqlite3 "$dst" "PRAGMA integrity_check;" 2>/dev/null | grep -q ok || { echo "ERROR: integrity failed: $db" >&2; return 1; }
}

drain_mirror() {
  local name="$1" src="$2" rel="$3"
  [[ -d "$src" ]] || { log "skip : $name missing ($src)"; return 0; }
  local staging="$DEST/.drain/$name"
  [[ $DRY_RUN -eq 0 ]] && mkdir -p "$staging"
  local db
  while IFS= read -r db; do sqlite_drain "$db" "$staging" || return 1; done < <(
    find "$src" \( -name "*.sqlite" -o -name "places.sqlite" -o -name "History" -o -name "Cookies" -o -name "*history*.sqlite" \) ! -path '*/Cache/*' 2>/dev/null)
  rsync_mirror "$name" "$src" "$rel"
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
    # stage only the included entries, preserving hierarchy
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
  sha256sum "$DEST/$rel.tar.gz" > "$DEST/$rel.tar.gz.sha256"
}

# --- per-source dispatch ------------------------------------------------------
run_source() {
  local id="$1" kind="$2" root="$3" destrel="$4" label="$5" extra="$6"
  label="${label:-$id}"
  local src
  src="$(expand_home "$root")"
  [[ -e "$src" ]] || { log "skip : $label missing ($src)"; return 0; }

  # interactive confirmation
  if [[ $ASK -eq 1 ]]; then
    printf 'Include %s? [Y/n/!] ' "$label"
    read -r ans
    case "${ans:-Y}" in [nN]) echo "  skipped: $label"; return 0 ;; esac
  fi

  case "$kind" in
    dir) rsync_mirror "$id" "$src" "$destrel" ;;
    drain) drain_mirror "$id" "$src" "$destrel" ;;
    tar) tar_blob "$id" "$src" "$destrel" "$extra" ;;
    snapshot) : ;; # handled separately below
  esac
}

# --- browsers source (drain) --------------------------------------------------
run_browsers() {
  local destrel="$1"
  local name root
  browser_rows "$plat" | while read -r name root; do
    local r
    r="$(expand_home "$root")"
    [[ -d "$r" ]] || { log "skip browser: $name missing ($r)"; continue; }
    drain_mirror "$name" "$r" "$destrel/$name"
  done
}

# --- snapshot source ----------------------------------------------------------
run_snapshot() {
  local destrel="$1"
  if [[ $DRY_RUN -eq 1 ]]; then echo "DRY: snapshot -> $DEST/$destrel/snapshot.txt"; return 0; fi
  mkdir -p "$DEST/$destrel"
  log "snap : system-state"
  {
    echo "## system-state snapshot ($(date -Is))"
    echo "platform=$plat"
    echo "os_release=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
    echo "--- dpkg/apt packages (first 300) ---"
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | head -300
    echo "--- flatpak apps ---"
    flatpak list --app --columns=application 2>/dev/null || true
    echo "--- fstab ---"
    cat /etc/fstab 2>/dev/null
    echo "--- systemd user units ---"
    systemctl --user list-unit-files --no-pager 2>/dev/null | head -40
    echo "--- toolchain dirs (info) ---"
    du -sh "$home"/.nvm "$home"/.rustup "$home"/.cargo "$home"/.sdkman "$home"/go "$home"/.bun "$home"/.npm 2>/dev/null || true
  } > "$DEST/$destrel/snapshot.txt" 2>/dev/null
}

# ===========================================================================
log "backup start (platform=$plat, presets/${IDS})"

# snapshot source (system state) uses its own transporter
SNAP_DEST="system-state"
# toolchains source is informational; fold into snapshot
run_snapshot "$SNAP_DEST"

# browsers handled via browser_rows (not the source root)
BROWSER_DEST=""
for id in $IDS; do
  line="$(render_catalog "$plat" | grep -P "^$id\t" | head -1 || true)"
  [[ -z "$line" ]] && continue
  kind="$(printf '%s' "$line" | cut -f2)"
  root="$(printf '%s' "$line" | cut -f4)"
  destrel="$(printf '%s' "$line" | cut -f5)"
  label="$(printf '%s' "$line" | cut -f6)"
  extra="$(printf '%s' "$line" | cut -f7)"
  if [[ "$id" == "browsers" ]]; then
    run_browsers "$destrel"
    continue
  fi
  run_source "$id" "$kind" "$root" "$destrel" "$label" "$extra"
done

if [[ $DRY_RUN -eq 1 ]]; then echo "DRY-RUN complete"; exit 0; fi

cp -a "$BB_CATALOG" "$DEST/manifest.yml" 2>/dev/null
cp -a "$BB_USER" "$DEST/user.yml" 2>/dev/null
echo "backup finished -> $DEST"
exit 0
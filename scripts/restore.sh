#!/usr/bin/env bash
# backup-ops: generic restore engine.
#   restore.sh --from <backup-root> [--to <restore-home>] [--dry-run]
#              [--preset full] [--include a,b] [--exclude a,b] [--ask]
#
# Uses the SAME config/manifest.yml catalog as backup, so a backup made on any
# platform (Linux / Windows / macOS / WSL) restores onto any other: each source's
# dest/ is mapped back through the CURRENT platform's root (e.g. a Windows backup
# of browser "brave" under User Data restores into the Linux flatpak path).

set -uo pipefail

BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

FROM=""; TO=""; DRY_RUN=0; PRESET=""; INCLUDE=""; EXCLUDE_LIST=""; ASK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --preset) PRESET="$2"; shift 2 ;;
    --include) INCLUDE="$2"; shift 2 ;;
    --exclude) EXCLUDE_LIST="$2"; shift 2 ;;
    --ask) ASK=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

LOGFILE="$BB_PROJ_DIR/data/run-log.md"
log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOGFILE"; }

TO="${TO:-$HOME}"
FROM="${FROM:-}"
[[ -n "$FROM" && -d "$FROM" ]] || { echo "ERROR: --from must point at a backup root (got: '$FROM')" >&2; exit 2; }

# Everything restores under --to (the new home). Default is the current $HOME.
# Setting HOME_BASE makes lib.sh's expand_home resolve every catalog root there.
export HOME_BASE="${TO%/}"

plat="$(resolve_platform)"
home="$(expand_home '~')"
echo "platform=$plat restore-to=$TO from=$FROM"

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
[[ -n "$IDS" ]] || { echo "nothing selected"; exit 0; }
echo "restore selection: ${IDS}"

run() { # run <desc> <cmd...>
  local desc="$1"; shift
  echo "  $desc"
  if [[ $DRY_RUN -eq 1 ]]; then printf '    %s\n' "$*"; return 0; fi
  "$@"
}

restore_dirs() {
  # restore from dest/ dir mirror -> current platform root
  local id="$1" label="$2"
  local catalog_line src_root
  catalog_line="$(render_catalog "$plat" | grep -P "^$id\t" | head -1 || true)"
  src_root="$(printf '%s' "$catalog_line" | cut -f4)"
  [[ -n "$src_root" ]] || { echo "  no root for $id on $plat; skipped"; return 0; }
  local target dir
  target="$(expand_home "$src_root")"
  local mirror="$FROM/$(printf '%s' "$catalog_line" | cut -f5)"
  [[ -d "$mirror" ]] || { echo "  $id: no mirror at $mirror"; return 0; }
  [[ $DRY_RUN -eq 0 ]] && mkdir -p "$(dirname "$target")"
  run "restore $id -> $target" rsync -aAX --ignore-existing "$mirror/" "$target/"
}

restore_tar() {
  local id="$1" label="$2" extra="$3"
  local tarball
  tarball="$(ls "$FROM/$(render_catalog "$plat" | grep -P "^$id\t" | head -1 | cut -f5)"*.tar.gz 2>/dev/null | head -1)"
  [[ -z "$tarball" ]] && tarball="$(find "$FROM" -path "*${id}*.tar.gz" 2>/dev/null | head -1)"
  [[ -n "$tarball" ]] || { echo "  $id: no tar found"; return 0; }

  # determine print target for the user
  local catalog_line src_root
  catalog_line="$(render_catalog "$plat" | grep -P "^$id\t" | head -1 || true)"
  src_root="$(printf '%s' "$catalog_line" | cut -f4)"

  # The catalog root for the CURRENT platform already resolves every target
  # (~ for dotfiles/histories/secrets, ~/.config for configs, %APPDATA% on
  # Windows…). HOME_BASE is exported, so expand_home maps it under --to.
  local target
  target="$(expand_home "$src_root")"
  mkdir -p "$target" 2>/dev/null

  run "restore $id -> $target" tar -xzf "$tarball" --overwrite -C "$target" .
}

# secrets carry extra permission care
fix_secrets_perms() {
  if [[ $DRY_RUN -eq 1 ]]; then return; fi
  chmod 700 "$TO/.ssh" "$TO/.gnupg" 2>/dev/null || true
  chmod 600 "$TO"/.ssh/id_* "$TO"/.gnupg/* 2>/dev/null || true
  chmod 644 "$TO"/.ssh/*.pub 2>/dev/null || true
}

# browsers: drain profiles were duplicated under DEST/.drain/<name>/ (flat sqlite)
# AND mirrored under DEST/<browser-dest>/<name>/ — restore the mirror.
restore_browsers() {
  local browser_dest
  browser_dest="$(render_catalog "$plat" | grep -P '^browsers\t' | head -1 | cut -f5)"
  [[ -d "$FROM/$browser_dest" ]] || { echo "  browsers: no mirror"; return 0; }
  local name root
  browser_rows "$plat" | while IFS=$'\t' read -r name root _bex; do
    local mirror="$FROM/$browser_dest/$name"
    [[ -d "$mirror" ]] || { echo "  browser $name: no data in backup"; continue; }
    local target
    target="$(expand_home "$root")"
    [[ -n "$target" ]] || { echo "  browser $name: no root on $plat; skipped"; continue; }
    if [[ $ASK -eq 1 ]]; then
      printf 'Restore %s -> %s? [Y/n] ' "$name" "$target"; read -r ans
      case "${ans:-Y}" in [nN]) echo "  skipped: $name"; continue ;; esac
    fi
    [[ $DRY_RUN -eq 0 ]] && mkdir -p "$(dirname "$target")"
    run "browser $name -> $target" rsync -aAX --ignore-existing "$mirror/" "$target/"
  done
}

# ===========================================================================
for id in $IDS; do
  line="$(render_catalog "$plat" | grep -P "^$id\t" | head -1 || true)"
  [[ -z "$line" ]] && continue
  kind="$(printf '%s' "$line" | cut -f2)"
  label="$(printf '%s' "$line" | cut -f6)"
  extra="$(printf '%s' "$line" | cut -f7)"
  label="${label:-$id}"
  case "$kind" in
    dir) restore_dirs "$id" "$label" ;;
    tar) restore_tar "$id" "$label" "$extra"
         [[ "$id" == "secrets" ]] && fix_secrets_perms ;;
    drain) [[ "$id" == "browsers" ]] && restore_browsers ;;
    snapshot) echo "  $label: informational only (see $FROM/$(printf '%s' "$line" | cut -f5)/snapshot.txt)";;
    *) echo "  $label: unknown kind $kind" ;;
  esac
done

echo
echo "restore complete: $FROM -> $TO"
[[ $DRY_RUN -eq 1 ]] && echo "(dry-run — nothing written)"
exit 0
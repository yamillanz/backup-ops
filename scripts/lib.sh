#!/usr/bin/env bash
# backup-ops: shared engine library. Sourced by backup.sh / restore.sh / verify.sh.
#
# Everything here is platform- and config-aware. The two key constructs:
#
#   * CONFIG CATALOG  config/manifest.yml  (COMMITTED, generic)
#       Declarative list of "sources" (what can be backed up) + presets + kinds.
#       Each source has per-platform roots so the SAME manifest works on
#       Linux / Windows (Git-Bash or WSL) / macOS.
#
#   * USER SELECTION  config/user.yml      (gitignored, personal)
#       What YOU actually selected (source ids), destination drive, language.
#       Written by the `start` wizard; empty = use default preset.
#
# Source kinds:
#   dir      -> rsync mirror of a full tree        (big folders)
#   tar      -> single .tar.gz + sha256            (config/dotfile blobs)
#   drain    -> WAL-safe SQLite snapshots + rsync  (browsers / any DB-heavy dir)
#   snapshot -> generated text files (system state), not file copies

set -uo pipefail

# ---- paths ------------------------------------------------------------------
BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BB_PROJ_DIR="$(cd "$BB_SCRIPT_DIR/.." && pwd)"
BB_CATALOG="$BB_PROJ_DIR/config/manifest.yml"
BB_USER="$BB_PROJ_DIR/config/user.yml"
BB_EXCLUDES="$BB_PROJ_DIR/config/global-excludes.txt"

# ---------------------------------------------------------------------------
# detect_platform: linux | windows | macos | wsl
#   Windows under Git-Bash sets MSYSTEM; WSL sets WSL_DISTRO_NAME; macOS is Darwin.
detect_platform() {
  if [[ -n "${WSL_DISTRO_NAME:-}" || "$(uname -r 2>/dev/null)" == *microsoft* ]]; then
    echo "wsl"
  elif [[ -n "${MSYSTEM:-}" || "$(uname -s 2>/dev/null)" == MINGW* || "$(uname -s 2>/dev/null)" == MSYS* ]]; then
    echo "windows"
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    echo "macos"
  else
    echo "linux"
  fi
}

# ---------------------------------------------------------------------------
# expand_home <path>: expand ~/%USERPROFILE%/%LOCALAPPDATA%/%APPDATA%/$VAR...
# Works whether run under bash-on-linux, git-bash on Windows, or WSL.
# Set HOME_BASE=<dir> (export) to force the ~ base (used by drill tests).
expand_home() {
  local p="$1"
  local base="${HOME_BASE:-$HOME}"
  p="${p//\~\//"$base"/}"
  p="${p//\~/"$base"}"
  p="${p//%USERPROFILE%/"${USERPROFILE:-$base}"}"
  p="${p//%LOCALAPPDATA%/"${LOCALAPPDATA:-$base/AppData/Local}"}"
  p="${p//%APPDATA%/"${APPDATA:-$base/AppData/Roaming}"}"
  p="${p//%HOME%/"$base"}"
  # generic %VAR% expansion for any other env var (Windows/Git-Bash)
  while [[ "$p" =~ (%[A-Za-z_][A-Za-z0-9_]*%) ]]; do
    local name="${BASH_REMATCH[1]//%/}"; local val="${!name:-}"
    p="${p//%$name%/$val}"
    [[ -n "$val" ]] || break
  done
  echo "$p"
}

# ---------------------------------------------------------------------------
# yaml_get <file> <key>: print scalar value of `key: value` (first occurrence),
# with any trailing `# comment` and surrounding quotes stripped.
yaml_get() {
  local f="$1" key="$2" v
  v="$(sed -n "s/^[[:space:]]*$key:[[:space:]]*//p" "$f" | head -1)"
  printf '%s' "$v" | strip_comment | strip_quotes
}

yaml_get_dotted() {
  local f="$1" dotted="$2"
  local pat="${dotted//./[[:space:]]*}"
  awk -v pat="^$dotted:" '$0 ~ pat { sub(/^[^:]*:[[:space:]]*/,""); print; exit }' "$f"
}

# ---------------------------------------------------------------------------
# strip_quotes / strip_comment: small helpers for YAML scalar cleaning.
strip_quotes()  { sed 's/^["'"'"']//; s/["'"'"']$//'; }
strip_comment() { sed 's/[[:space:]]*#.*$//'; }

# ---------------------------------------------------------------------------
# render_catalog [platform]: emit ONE line per source:
#   id<TAB>kind<TAB>enabled<TAB>root<TAB>dest<TAB>label<TAB>extra
# root is resolved for the given platform (empty if N/A). extra carries
#   include|a|include|b|exclude|x  (pairs, | separated).
render_catalog() {
  local plat="${1:-$(detect_platform)}"
  awk -v plat="$plat" -F: 'BEGIN { OFS="\t" }
    /^sources:/ { in_sources=1; next }
    in_sources && /^[[:space:]]*-[[:space:]]*id:/ {
      if (cur_id != "" && cur_id != "- id") print_line()
      cur_id=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", cur_id)
      cur_kind="dir"; cur_enabled="false"; cur_root=""; cur_dest=""; cur_label=""
      cur_extra=""; cur_mode=""; block=1; next
    }
    in_sources && /^[[:space:]]+kind:/    { cur_kind=trimv($2); next }
    in_sources && /^[[:space:]]+enabled:/ { cur_enabled=trimv($2); sub(/#.*$/, "", cur_enabled); gsub(/[[:space:]]+/,"",cur_enabled); next }
    in_sources && /^[[:space:]]+dest:/    { cur_dest=trimv($2); next }
    in_sources && /^[[:space:]]+label:/   { cur_label=restof($0); next }
    in_sources && /^[[:space:]]+include_only:/ { cur_mode="include"; next }
    in_sources && /^[[:space:]]+exclude:/ { cur_mode="exclude"; next }
    in_sources && cur_mode != "" && /^[[:space:]]+-[[:space:]]/ {
      item=restof($0); gsub(/^[[:space:]]*-[[:space:]]*/, "", item); gsub(/["'"'"']/, "", item)
      cur_extra=cur_extra (cur_extra=="" ? "" : "|") cur_mode "|" item
      next
    }
    in_sources && cur_mode != "" && !/^[[:space:]]+-[[:space:]]/ { cur_mode="" }
    in_sources && /^[[:space:]]+platforms:/ { cur_plat=1; next }
    in_sources && cur_plat && /^[[:space:]]{6}[a-z_]+:/ {
      k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      v=trimv($2); gsub(/["'"'"']/, "", v)
      if (k==plat && v!="") cur_root=v
      next
    }
    in_sources && cur_plat && /^[[:space:]]+[a-z_]+:/ && $0 !~ /^[[:space:]]{6}/ { cur_plat=0 }
    in_sources && /^[[:space:]]{0}[a-z_]+:/ { in_sources=0 }
    END { if (cur_id != "" && cur_id != "- id") print_line() }
    function trimv(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function restof(line) { sub(/^[^:]*:[[:space:]]*/, "", line); return trimv(line) }
    function print_line() { print cur_id, cur_kind, cur_enabled, cur_root, cur_dest, cur_label, cur_extra }
  ' "$BB_CATALOG"
}

# ---------------------------------------------------------------------------
# preset_ids <name>: source ids that belong to a top-level preset group, e.g.
#   presets:
#     essentials:
#       - documents
preset_ids() {
  local name="$1"
  awk -v want="$name" '
    /^presets:/ { in_presets=1; next }
    in_presets && /^[[:space:]]{0}[a-z_]+:/ && $0 !~ /^[[:space:]]/ { exit }
    in_presets && /^[[:space:]]{2}[a-z_]+:/ { cur_group=$1; sub(/:/,"",cur_group); next }
    in_presets && cur_group==want && /^[[:space:]]{4}-[[:space:]]*[a-zA-Z0-9_]+/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); print
    }
  ' "$BB_CATALOG"
}

# ---------------------------------------------------------------------------
# browser_rows [platform]: per-browser root lines:
#   <name><TAB><root><TAB><exclude|list>   (root empty if N/A on this OS)
# The 3rd field carries the per-browser `exclude: [...]` rules from the catalog
# (pipe-separated) so callers can forward them to rsync — data, not code.
browser_rows() {
  local plat="${1:-$(detect_platform)}"
  awk -v plat="$plat" 'BEGIN { OFS="\t" }
    /^[[:space:]]{4}browsers:/ { in_browsers=1; next }
    in_browsers && /^[[:space:]]{6}[a-z_]+:$/ {
      if (cur) print cur, cur_root, cur_ex
      cur=$1; sub(/:/,"",cur); cur_root=""; cur_ex=""; next
    }
    in_browsers && /^[[:space:]]{8}exclude:/ {
      line=$0
      sub(/^[[:space:]]*exclude:[[:space:]]*\[/, "", line); sub(/\][[:space:]]*$/, "", line)
      gsub(/["'"'"']/, "", line); gsub(/,[[:space:]]*/, "|", line)
      cur_ex=line; next
    }
    in_browsers && /^[[:space:]]{8}[a-z_]+:/ {
      k=substr($0,9); sub(/:.*/,"",k)
      v=substr($0,10+length(k)); sub(/^[[:space:]]+/,"",v); gsub(/["'"'"']/,"",v)
      if (k==plat && v!="") cur_root=v
      next
    }
    in_browsers && /^[[:space:]]{4}[a-z_]+:/ && $0 !~ /^[[:space:]]{6,}/ { in_browsers=0 }
    END { if (cur) print cur, cur_root, cur_ex }
  ' "$BB_CATALOG"
}

# ---------------------------------------------------------------------------
# safety_get <key>: read a knob from the catalog's top-level `safety:` block
# (e.g. `safety_get free_space_min_gb`). Empty when absent.
safety_get() {
  local key="$1"
  awk -v key="$key" '
    /^safety:/ { in_s=1; next }
    in_s && /^[[:space:]]+[a-z_]+:/ {
      k=$1; sub(/:/, "", k)
      if (k == key) {
        v=$2; sub(/#.*$/, "", v); gsub(/[[:space:]]+/, "", v)
        print v; exit
      }
      next
    }
    in_s && $0 !~ /^[[:space:]]/ { in_s=0 }
  ' "$BB_CATALOG"
}

# ---------------------------------------------------------------------------
# load_excludes <nameref>: fill the caller's array from global + catalog cleanup.
# Catalog sources may carry their own extra excludes (see catalog), merged here
# so the caller passes one --exclude-from list per source.
load_excludes() {
  local -n _arr="$1"
  _arr=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    _arr+=(--exclude="${line//~\//}")
  done < "$BB_EXCLUDES"
}

# ---------------------------------------------------------------------------
# user_yml <key>: value from config/user.yml (personal layer, may be absent).
user_yml() {
  local k="$1" v
  v="$([[ -f "$BB_USER" ]] && sed -n "s/^[[:space:]]*$k:[[:space:]]*//p" "$BB_USER" | head -1)"
  printf '%s' "$v" | strip_comment | strip_quotes
}

# ---------------------------------------------------------------------------
# active_ids [preset]: source ids in effect for the current user.
#   precedence: user.yml `selection:` list > user.yml `preset:` > catalog default_preset
active_source_ids() {
  local preset="${1:-$(user_yml preset)}"
  local sel
  sel="$(user_yml selection)"
  sel="$(printf '%s' "$sel" | tr -d '[]"' | tr ',' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$sel" ]]; then
    for id in $sel; do [[ -n "$id" ]] && echo "$id"; done
    return
  fi
  [[ -z "$preset" ]] && preset="$(yaml_get "$BB_CATALOG" default_preset)"
  preset="$(printf '%s' "$preset" | tr -d '[]"')"
  [[ -z "$preset" ]] && preset="essentials"
  preset_ids "$preset"
}

# ---------------------------------------------------------------------------
# active_rows [platform]: render_catalog filtered to the IDs in effect for the
# current user and THIS platform (root non-empty). TSV lines only.
active_rows() {
  local plat="${1:-$(detect_platform)}"
  local -A want=()
  local id
  while IFS= read -r id; do [[ -n "$id" ]] && want["$id"]=1; done < <(active_source_ids)
  local line id kind root
  while IFS= read -r line; do
    id="${line%%$'\t'*}"
    kind="$(printf '%s' "$line" | cut -f2)"
    root="$(printf '%s' "$line" | cut -f4)"
    # snapshot sources have no source root (they generate files) — always eligible
    [[ -n "${want[$id]:-}" && ( -n "$root" || "$kind" == "snapshot" ) ]] && echo "$line"
  done < <(render_catalog "$plat")
}

# ---------------------------------------------------------------------------
# resolve_platform: catalog may pin platform; else auto-detect.
resolve_platform() {
  local cfg
  cfg="$(yaml_get "$BB_CATALOG" platform)"
  [[ -n "$cfg" && "$cfg" != "auto" ]] && echo "$cfg" || detect_platform
}

# ---------------------------------------------------------------------------
# dest_root: the effective backup destination (from user.yml > catalog).
dest_root() {
  local r
  r="$(user_yml destination)"
  [[ -z "$r" ]] && r="$(yaml_get "$BB_CATALOG" default_destination)"
  expand_home "$r"
}
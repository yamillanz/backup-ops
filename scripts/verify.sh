#!/usr/bin/env bash
# backup-ops: verification engine. Proves a backup or restored tree is honest.
# Usage:
#   verify.sh --tree <path>               # backup-tree checks
#   verify.sh --tree <path> --restored    # also check user-layout + dotfile parse
#
# Outputs a human table + machine JSON at data/last-run.json.

set -uo pipefail

BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

TREE=""; RESTORED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) TREE="$2"; shift 2 ;;
    --restored) RESTORED=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TREE" ]] || { echo "usage: verify.sh --tree <path> [--restored]" >&2; exit 2; }
[[ -d "$TREE" ]] || { echo "ERROR: tree does not exist: $TREE" >&2; exit 3; }

RESULTS="$BB_PROJ_DIR/data/last-run.json"
declare -A RESULTS_MAP
FAIL=0
declare -a FAILED_LINES

check() { local name="$1" desc="$2" passed="$3"
  if [[ "$passed" -eq 0 ]]; then RESULTS_MAP["$name"]="PASS"; echo "  ✅ $name: $desc"
  else RESULTS_MAP["$name"]="FAIL"; FAIL=$((FAIL+1)); FAILED_LINES+=("$name: $desc"); echo "  ❌ $name: $desc"; fi
}

dir_nonempty() { local label="$1" dir="$2"
  # accept a directory with contents OR a tarball at the same path
  if [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then check "$label" "$dir" 0
  elif [[ -f "$dir.tar.gz" ]] && [[ -s "$dir.tar.gz" ]]; then check "$label" "$dir.tar.gz" 0
  else check "$label" "$dir" 1; fi
}

echo "verification: $TREE"

# --- backup-tree structural checks -------------------------------------------
if [[ $RESTORED -eq 0 ]]; then
  plat="$(resolve_platform)"
  echo "  (platform=$plat, verifying only active+present sources)"

  # presence-aware: a section is REQUIRED only if its source is in the active
  # selection AND its root exists on this machine at backup time.
  id=""; kind=""; root=""; destrel=""
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | cut -f1)"
    kind="$(printf '%s' "$line" | cut -f2)"
    root="$(printf '%s' "$line" | cut -f4)"
    destrel="$(printf '%s' "$line" | cut -f5)"
    [[ -n "$root" || "$kind" == "snapshot" ]] || continue
    if [[ "$kind" == "snapshot" ]]; then
      # generated content: no source root to check — require the dest output
      dir_nonempty "$id" "$TREE/$destrel"
      continue
    fi
    r="$(expand_home "$root")"
    if [[ ! -e "$r" ]]; then
      echo "  ℹ skipped-missing source: $id ($r not on this machine)"
      continue
    fi
    case "$kind" in
      dir)
        dir_nonempty "dir/$id" "$TREE/$destrel"
        ;;
      tar)
        dir_nonempty "tar/$id" "$TREE/$destrel"
        ;;
      drain)
        # browsers populated only when at least one browser exists on the machine
        any=0
        while IFS=$'\t' read -r n br _bex; do
          br="$(expand_home "$br")"
          [[ -d "$br" ]] && any=1
        done < <(browser_rows "$plat")
        if [[ $any -eq 1 ]]; then dir_nonempty "browsers" "$TREE/$destrel"; else echo "  ℹ no browsers on this machine — browsers section skipped (expected)"; fi
        ;;
    esac
  done < <(active_rows "$plat")

  # sqlite integrity in drained browser copies
  sqlite_ok=0
  while IFS= read -r db; do
    if sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -q ok; then :; else
      sqlite_ok=1; FAILED_LINES+=("sqlite torn: $db"); echo "  ❌ sqlite integrity: $db"
    fi
  done < <(find "$TREE/.drain" -name "*.sqlite" 2>/dev/null | head -50)
  check "browser_sqlite" "drained browser DBs" "$sqlite_ok"

  # tar archives readable + checksum
  tar_ok=0
  while IFS= read -r tarball; do
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
      tar_ok=1; FAILED_LINES+=("tar corrupt: $tarball"); echo "  ❌ tar readable: $tarball"
    fi
    if [[ -f "$tarball.sha256" ]] && ! (cd "$(dirname "$tarball")" && sha256sum -c "$(basename "$tarball.sha256")") >/dev/null 2>&1; then
      tar_ok=1; FAILED_LINES+=("sha mismatch: $tarball"); echo "  ❌ sha256: $tarball"
    fi
  done < <(find "$TREE" -name "*.tar.gz" 2>/dev/null)
  check "tar_archives" "tars readable + checksums" "$tar_ok"
fi

# --- restored-side checks -----------------------------------------------------
if [[ $RESTORED -eq 1 ]]; then
  echo "restored-side checks:"
  dotfile_ok=0
  if [[ -f "$TREE/.zshrc" ]] && command -v zsh >/dev/null 2>&1; then
    zsh -n "$TREE/.zshrc" >/dev/null 2>&1 || dotfile_ok=1
  fi
  if [[ -f "$TREE/.bashrc" ]] && command -v bash >/dev/null 2>&1; then
    bash -n "$TREE/.bashrc" >/dev/null 2>&1 || dotfile_ok=1
  fi
  check "dotfiles_parse" ".zshrc/.bashrc parse" "$dotfile_ok"

  secret_perm_ok=0
  if [[ -d "$TREE/.ssh" ]]; then
    for key in "$TREE"/.ssh/id_*; do
      [[ -f "$key" ]] || continue
      mode=$(stat -c %a "$key" 2>/dev/null)
      [[ "$mode" == "600" ]] || { secret_perm_ok=1; FAILED_LINES+=("ssh key perms $mode: $key"); echo "  ❌ ssh perms: $key ($mode)"; }
    done
  fi
  check "secret_perms" "ssh key perms 600" "$secret_perm_ok"

  # restored layout: verify the sources the catalog knows for this platform
  id=""; root=""; r=""
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | cut -f1)"
    root="$(printf '%s' "$line" | cut -f4)"
    r="$(expand_home "$root")"
    if [[ -d "$r" ]] && [[ -n "$(ls -A "$r" 2>/dev/null)" ]]; then
      echo "  ✅ restored: $id ($r)"
    fi
  done < <(render_catalog "$(resolve_platform)")
fi

# --- summary ---------------------------------------------------------------
echo
if [[ $FAIL -eq 0 ]]; then echo "OS-VERIFY: PASS"; else
  echo "OS-VERIFY: FAIL ($FAIL issue(s))"
  printf '  - %s\n' "${FAILED_LINES[@]}"
fi

{
  echo "{"
  echo "  \"tree\": \"$TREE\","
  echo "  \"date\": \"$(date -Iseconds)\","
  echo "  \"restored_side\": $RESTORED,"
  echo "  \"pass\": $([ $FAIL -eq 0 ] && echo true || echo false),"
  echo "  \"sections\": {"
  _first=1
  for _k in "${!RESULTS_MAP[@]}"; do
    [[ $_first -eq 1 ]] || echo ","
    printf '    "%s": "%s"' "$_k" "${RESULTS_MAP[$_k]}"
    _first=0
  done
  echo
  echo "  }"
  echo "}"
} > "$RESULTS"

exit $FAIL
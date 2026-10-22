#!/usr/bin/env bash
# backup-ops: verification engine. Proves a backup or restored tree is honest.
# Usage:
#   verify.sh --tree <path>               # backup-tree checks
#   verify.sh --tree <path> --restored    # also check user-layout + dotfile parse
#
# The backup's own migration.yml selection is authoritative; a legacy backup
# falls back to this host's active selection with a warning. Outputs a human
# table + machine JSON at data/last-run.json.

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
if command -v realpath >/dev/null 2>&1; then TREE="$(realpath -m "$TREE")"; fi

RESULTS="$BB_PROJ_DIR/data/last-run.json"
declare -A RESULTS_MAP
FAIL=0
WARN=0
declare -a FAILED_LINES

check() { local name="$1" desc="$2" passed="$3"
  if [[ "$passed" -eq 0 ]]; then RESULTS_MAP["$name"]="PASS"; echo "  ✅ $name: $desc"
  else RESULTS_MAP["$name"]="FAIL"; FAIL=$((FAIL+1)); FAILED_LINES+=("$name: $desc"); echo "  ❌ $name: $desc"; fi
}

warn() { local name="$1" desc="$2"
  RESULTS_MAP["$name"]="WARN"; WARN=$((WARN+1)); echo "  ⚠️  $name: $desc"
}

dir_nonempty() { local label="$1" dir="$2"
  if [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then check "$label" "$dir" 0
  elif [[ -f "$dir.tar.gz" ]] && [[ -s "$dir.tar.gz" ]]; then check "$label" "$dir.tar.gz" 0
  else check "$label" "$dir" 1; fi
}

tar_readable() { local tarball="$1"
  local ok=0
  tar -tzf "$tarball" >/dev/null 2>&1 || ok=1
  if [[ -f "$tarball.sha256" ]]; then
    ( cd "$(dirname "$tarball")" && sha256sum -c "$(basename "$tarball.sha256")" ) >/dev/null 2>&1 || ok=1
  fi
  return $ok
}

echo "verification: $TREE"

# --- backup-tree structural checks -------------------------------------------
if [[ $RESTORED -eq 0 ]]; then
  plat="$(resolve_platform)"
  echo "  (platform=$plat, backup selection authoritative)"

  SEL="$(yaml_get "$TREE/migration.yml" selection 2>/dev/null)"
  [[ -z "$SEL" && -f "$TREE/backup-info.yml" ]] && SEL="$(yaml_get "$TREE/backup-info.yml" selection 2>/dev/null)"
  if [[ -z "$SEL" ]]; then
    SEL="$(active_source_ids | tr '\n' ' ')"
    warn "selection" "no migration.yml/backup-info.yml selection; using this host's active selection (legacy backup)"
  fi
  declare -A WANT=()
  for id in $SEL; do WANT["$id"]=1; done

  id=""; kind=""; root=""; destrel=""
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | cut -f1)"
    kind="$(printf '%s' "$line" | cut -f2)"
    root="$(printf '%s' "$line" | cut -f4)"
    destrel="$(printf '%s' "$line" | cut -f5)"
    [[ -n "${WANT[$id]:-}" ]] || continue
    [[ -n "$root" || "$kind" == "snapshot" ]] || continue

    if [[ "$kind" == "snapshot" ]]; then
      dir_nonempty "snapshot/$id" "$TREE/$destrel"
      case "$id" in
        packages)
          [[ -f "$TREE/$destrel/native-explicit.txt" ]] || check "packages_inventory" "$TREE/$destrel/native-explicit.txt missing" 1
          if [[ -f "$TREE/$destrel/native-explicit.txt" && ! -s "$TREE/$destrel/native-explicit.txt" ]]; then
            warn "packages_empty" "native-explicit.txt is empty (unsupported package manager?)"
          fi
          ;;
        system_files)
          [[ -s "$TREE/$destrel/manifest.tsv" ]] || check "system_files_manifest" "$TREE/$destrel/manifest.tsv missing/empty" 1
          if [[ -s "$TREE/$destrel/manifest.tsv" ]] && ! awk -F'\t' '$2=="ok"||$2=="ok-sudo"{found=1} END{exit found?0:1}' "$TREE/$destrel/manifest.tsv"; then
            warn "system_files_permissions" "no /etc file could be copied without sudo; review manifest.tsv"
          fi
          ;;
        network)
          [[ -s "$TREE/$destrel/manifest.tsv" ]] || check "network_manifest" "$TREE/$destrel/manifest.tsv missing/empty" 1
          if [[ -d "$TREE/$destrel" ]] && find "$TREE/$destrel" -type f ! -perm 600 2>/dev/null | grep -q .; then
            check "network_perms" "network files are not 600" 1
          else
            check "network_perms" "network files 600" 0
          fi
          ;;
        virtualization)
          if find "$TREE/$destrel" -name '*.xml' 2>/dev/null | grep -q .; then
            if command -v python3 >/dev/null 2>&1; then
              if python3 - "$TREE/$destrel" <<'PY' >/dev/null 2>&1
import glob, sys, xml.etree.ElementTree as ET
bad = 0
for p in glob.glob(sys.argv[1] + "/**/*.xml", recursive=True):
    try: ET.parse(p)
    except Exception: bad += 1
sys.exit(1 if bad else 0)
PY
              then check "virtualization_xml" "VM/network XML well-formed" 0
              else check "virtualization_xml" "VM/network XML malformed" 1; fi
            else warn "virtualization_xml" "python3 unavailable; XML not parsed"; fi
          fi
          ;;
        containers)
          if [[ -s "$TREE/$destrel/compose-files.txt" ]] && command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
            if python3 - "$TREE/$destrel/compose-files" <<'PY' >/dev/null 2>&1
import glob, sys, yaml
bad = 0
for p in glob.glob(sys.argv[1] + "/**/*.y*ml", recursive=True):
    try: yaml.safe_load(open(p, encoding="utf-8"))
    except Exception: bad += 1
sys.exit(1 if bad else 0)
PY
            then check "compose_yaml" "compose files parse" 0
            else check "compose_yaml" "compose files malformed" 1; fi
          elif [[ -s "$TREE/$destrel/compose-files.txt" ]]; then
            warn "compose_yaml" "PyYAML unavailable; compose files not parsed"
          fi
          ;;
        appimages)
          tsv="$TREE/$destrel/appimages.tsv"
          bad=0
          if [[ -s "$tsv" ]]; then
            while IFS=$'\t' read -r src rel sha mode; do
              [[ -n "$rel" ]] || continue
              f="$TREE/$destrel/$rel"
              [[ -f "$f" ]] || { bad=1; continue; }
              [[ -x "$f" ]] || bad=1
              [[ -n "$sha" ]] && [[ "$(sha256sum "$f" 2>/dev/null | awk '{print $1}')" == "$sha" ]] || bad=1
            done < "$tsv"
          fi
          check "appimages_exec_sha" "AppImage copies executable + sha256" "$bad"
          ;;
        audit)
          [[ -f "$TREE/$destrel/stray-files.txt" ]] || check "audit_files" "$TREE/$destrel/stray-files.txt missing" 1
          if [[ -f "$TREE/$destrel/status.txt" ]]; then warn "audit_timeout" "stray audit timed out/partial"; fi
          ;;
        gaming_saves)
          [[ -f "$TREE/$destrel/README.md" ]] || check "gaming_saves_readme" "$TREE/$destrel/README.md missing" 1
          ;;
      esac
      continue
    fi

    r="$(first_existing_root "$root" || true)"
    if [[ -z "$r" ]]; then
      echo "  ℹ skipped-missing source: $id ($root not on this machine)"
      continue
    fi
    case "$kind" in
      dir|tar)
        dir_nonempty "$kind/$id" "$TREE/$destrel"
        ;;
      drain)
        if [[ "$id" == "browsers" ]]; then
          any=0
          while IFS=$'\t' read -r n br _bex; do
            br="$(first_existing_root "$br" || true)"
            [[ -n "$br" ]] && any=1
          done < <(browser_rows "$plat")
          if [[ $any -eq 1 ]]; then dir_nonempty "browsers" "$TREE/$destrel"; else echo "  ℹ no browsers on this machine — browsers section skipped (expected)"; fi
        else
          dir_nonempty "$kind/$id" "$TREE/$destrel"
        fi
        ;;
    esac
  done < <(render_catalog "$plat")

  # --- integrity manifests ----------------------------------------------------
  if [[ -f "$TREE/manifest.sha256" ]]; then
    if ( cd "$TREE" && sha256sum -c manifest.sha256 >/dev/null 2>&1 ); then
      check "manifest_sha256" "all files match manifest.sha256" 0
    else
      check "manifest_sha256" "manifest.sha256 mismatch" 1
    fi
  else
    warn "manifest_sha256" "no manifest.sha256 (legacy backup)"
  fi

  if [[ -f "$TREE/migration.yml" ]]; then
    mf="$(yaml_get "$TREE/migration.yml" source_family)"
    ms="$(yaml_get "$TREE/migration.yml" selection)"
    [[ -n "$mf" && -n "$ms" ]] && check "migration_manifest" "source_family + selection present" 0 || check "migration_manifest" "migration.yml incomplete" 1
    if [[ -f "$TREE/manifest.yml" ]]; then
      want_hash="$(yaml_get "$TREE/migration.yml" catalog_sha256)"
      got_hash="$(sha256sum "$TREE/manifest.yml" 2>/dev/null | awk '{print $1}')"
      [[ -n "$want_hash" && "$want_hash" == "$got_hash" ]] && check "catalog_hash" "catalog matches backup" 0 || check "catalog_hash" "catalog hash mismatch" 1
    fi
  else
    warn "migration_manifest" "no migration.yml (legacy backup; safe-only restore)"
  fi

  if [[ -f "$TREE/backup-info.yml" ]]; then
    gaps="$(yaml_get "$TREE/backup-info.yml" critical_gaps)"
    [[ "${gaps:-0}" == "0" ]] && check "critical_gaps" "no critical coverage gaps" 0 || check "critical_gaps" "coverage gaps: ${gaps:-unknown}" 1
  else
    warn "backup_info" "no backup-info.yml"
  fi
  if [[ -f "$TREE/coverage-report.md" ]]; then
    if grep -q 'CRITICAL GAPS' "$TREE/coverage-report.md" 2>/dev/null; then
      check "coverage_report" "coverage report reports critical gaps" 1
    else
      check "coverage_report" "coverage report exists, no critical gaps" 0
    fi
  else
    warn "coverage_report" "no coverage-report.md"
  fi

  # --- source-specific checks -------------------------------------------------
  packages_native="$TREE/packages/native-explicit.txt"
  if [[ -n "${WANT[packages]:-}" && -f "$packages_native" ]]; then
    if [[ -s "$packages_native" ]]; then
      check "packages_parse" "native package inventory non-empty" 0
    else
      warn "packages_parse" "native package inventory empty"
    fi
  fi

  # sqlite integrity: drained DBs + browser mirrors
  sqlite_bad=0
  if command -v sqlite3 >/dev/null 2>&1; then
    while IFS= read -r db; do
      sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -q ok || { sqlite_bad=1; FAILED_LINES+=("sqlite torn: $db"); echo "  ❌ sqlite integrity: $db"; }
    done < <(find "$TREE/.drain" "$TREE/browsers" -type f \( -name '*.sqlite' -o -name 'places.sqlite' -o -name 'History' -o -name 'Cookies' \) 2>/dev/null | head -200)
  else
    warn "sqlite_tool" "sqlite3 unavailable; drained DBs not checked"
  fi
  check "browser_sqlite" "drained browser DBs" "$sqlite_bad"

  # tar archives readable + checksums
  tar_ok=0
  while IFS= read -r tarball; do
    tar_readable "$tarball" || { tar_ok=1; FAILED_LINES+=("tar corrupt/sha: $tarball"); echo "  ❌ tar: $tarball"; }
  done < <(find "$TREE" -name "*.tar.gz" 2>/dev/null)
  check "tar_archives" "tars readable + checksums" "$tar_ok"

  # no cache/trash payload
  cache_hits="$(find "$TREE" \( -path '*/.cache/*' -o -path '*/Cache/*' -o -path '*/cache/*' -o -path '*/cache2/*' -o -path '*/startupCache/*' -o -path '*/shader-cache/*' -o -path '*/Trash/*' -o -path '*/ShaderCache/*' \) 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${cache_hits:-0}" -eq 0 ]] && check "no_cache_payload" "no cache/trash payload" 0 || check "no_cache_payload" "$cache_hits cache/trash path(s) in backup" 1

  # ssh host keys copied by system_files must be 600
  if find "$TREE/system-files" -name 'ssh-ssh_host_*' -type f 2>/dev/null | grep -q .; then
    if find "$TREE/system-files" -name 'ssh-ssh_host_*' -type f ! -perm 600 2>/dev/null | grep -q .; then
      check "ssh_host_perms" "SSH host keys not 600" 1
    else
      check "ssh_host_perms" "SSH host keys 600" 0
    fi
  fi
fi

# --- restored-side checks -----------------------------------------------------
if [[ $RESTORED -eq 1 ]]; then
  export HOME_BASE="$TREE"
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
      [[ "$key" == *.pub ]] && continue
      mode=$(stat -c %a "$key" 2>/dev/null)
      [[ "$mode" == "600" ]] || { secret_perm_ok=1; FAILED_LINES+=("ssh key perms $mode: $key"); echo "  ❌ ssh perms: $key ($mode)"; }
    done
  fi
  check "secret_perms" "ssh key perms 600" "$secret_perm_ok"

  if [[ -d "$TREE/.local/share/keyrings" ]]; then
    kmode="$(stat -c %a "$TREE/.local/share/keyrings" 2>/dev/null)"
    [[ "$kmode" == "700" ]] && check "keyring_perms" "keyring dir 700" 0 || check "keyring_perms" "keyring dir mode $kmode (expected 700)" 1
  fi

  if [[ -f "$TREE/restore-info.yml" ]]; then
    profile="$(yaml_get "$TREE/restore-info.yml" profile)"
    legacy="$(yaml_get "$TREE/restore-info.yml" legacy)"
    applied="$(yaml_get "$TREE/restore-info.yml" applied)"
    staged="$(yaml_get "$TREE/restore-info.yml" staged)"
    failed_list="$(yaml_get "$TREE/restore-info.yml" failed)"
    src_de="$(yaml_get "$TREE/restore-info.yml" source_desktop)"
    tgt_de="$(yaml_get "$TREE/restore-info.yml" target_desktop)"
    [[ "$legacy" == "1" ]] && warn "restore_legacy" "legacy restore used safe-only policy"
    [[ -z "$failed_list" ]] && check "restore_failed" "no restore command failures" 0 || check "restore_failed" "restore failures: $failed_list" 1
    if [[ -n "$src_de" && -n "$tgt_de" && "$src_de" != "$tgt_de" ]]; then
      case " $applied " in
        *" desktop_env "*) check "desktop_gate" "desktop_env applied across different desktops" 1 ;;
        *) check "desktop_gate" "desktop_env not applied across different desktops" 0 ;;
      esac
    fi
    case " $staged " in
      *" desktop_env "*) [[ -d "$TREE/restore-manual/desktop_env" ]] && check "desktop_staged" "DE config staged for review" 0 || check "desktop_staged" "DE staged but restore-manual/desktop_env missing" 1 ;;
    esac
    case " $applied " in
      *" fonts_user "*)
        [[ -d "$TREE/.local/share/fonts" && -n "$(ls -A "$TREE/.local/share/fonts" 2>/dev/null)" ]] && check "fonts_restored" "user fonts restored" 0 || check "fonts_restored" "fonts_user applied but no fonts found" 1
        ;;
    esac
    if [[ -f "$TREE/migration-report.md" ]]; then check "migration_report" "migration report present" 0; else warn "migration_report" "no migration-report.md in restored home"; fi
    if [[ -d "$TREE/packages" ]]; then
      [[ -s "$TREE/packages/packages-to-install.txt" ]] && check "package_plan" "target package plan present" 0 || warn "package_plan" "packages dir present but no plan"
    fi
  else
    warn "restore_info" "no restore-info.yml (manual/legacy restore)"
  fi

  # browser DB integrity on the restored home
  browser_bad=0
  while IFS=$'\t' read -r name root _bex; do
    r="$(first_existing_root "$root" || true)"
    [[ -n "$r" ]] || continue
    while IFS= read -r db; do
      if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -q ok || { browser_bad=1; echo "  ❌ browser DB: $db"; }
      fi
    done < <(find "$r" -type f \( -name 'places.sqlite' -o -name 'History' -o -name 'Cookies' -o -name '*.sqlite' \) 2>/dev/null | head -100)
  done < <(browser_rows "$(resolve_platform)")
  check "restored_browser_sqlite" "restored browser DBs" "$browser_bad"

  # restored layout: only sources this restore actually applied/staged
  applied_list=""; staged_list=""
  if [[ -f "$TREE/restore-info.yml" ]]; then
    applied_list="$(yaml_get "$TREE/restore-info.yml" applied)"
    staged_list="$(yaml_get "$TREE/restore-info.yml" staged)"
  fi
  id=""; root=""; r=""
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | cut -f1)"
    root="$(printf '%s' "$line" | cut -f4)"
    in_applied=0; in_staged=0
    case " $applied_list " in *" $id "*) in_applied=1 ;; esac
    case " $staged_list " in *" $id "*) in_staged=1 ;; esac
    if [[ $in_staged -eq 1 ]]; then
      [[ -d "$TREE/restore-manual/$id" ]] && echo "  📦 staged: $id -> $TREE/restore-manual/$id"
      continue
    fi
    [[ $in_applied -eq 1 ]] || continue
    r="$(first_existing_root "$root" || true)"
    if [[ -n "$r" ]] && path_under "$r" "$TREE" && [[ -d "$r" ]] && [[ -n "$(ls -A "$r" 2>/dev/null)" ]]; then
      echo "  ✅ restored: $id ($r)"
    fi
  done < <(render_catalog "$(resolve_platform)")
fi

# --- summary ---------------------------------------------------------------
echo
if [[ $FAIL -eq 0 ]]; then
  if [[ $WARN -eq 0 ]]; then echo "OS-VERIFY: PASS"; else echo "OS-VERIFY: PASS ($WARN warning(s))"; fi
else
  echo "OS-VERIFY: FAIL ($FAIL issue(s), $WARN warning(s))"
  printf '  - %s\n' "${FAILED_LINES[@]}"
fi

{
  echo "{"
  echo "  \"tree\": \"$TREE\","
  echo "  \"date\": \"$(date -Iseconds)\","
  echo "  \"restored_side\": $RESTORED,"
  echo "  \"pass\": $([ $FAIL -eq 0 ] && echo true || echo false),"
  echo "  \"warnings\": $WARN,"
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

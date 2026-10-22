#!/usr/bin/env bash
# backup-ops: migration-aware restore engine.
#   restore.sh --from <backup-root> [--to <restore-home>] [--plan-only]
#              [--profile safe|same-de|verbatim] [--dry-run]
#              [--preset full] [--include a,b] [--exclude a,b] [--ask]
#
# Default is SAFE: app configs and data restore, desktop-environment state is
# staged for review unless the source and target desktop match and the user
# explicitly chooses --profile same-de. System files and network profiles are
# never auto-applied; they land in <to>/restore-manual/ with a checklist.
#
# The backup's migration.yml drives the selection and the report. A legacy
# backup without it restores only `always` sources and warns loudly.

set -uo pipefail

BB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$BB_SCRIPT_DIR/lib.sh"

FROM=""; TO=""; DRY_RUN=0; PLAN_ONLY=0; PROFILE=""; FORCE=0
PRESET=""; INCLUDE=""; EXCLUDE_LIST=""; ASK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --plan-only) PLAN_ONLY=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
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
TO="${TO%/}"
if command -v realpath >/dev/null 2>&1; then TO="$(realpath -m "$TO")"; fi
FROM="${FROM:-}"
[[ -n "$FROM" && -d "$FROM" ]] || { echo "ERROR: --from must point at a backup root (got: '$FROM')" >&2; exit 2; }
NO_WRITES=0
[[ $PLAN_ONLY -eq 1 || $DRY_RUN -eq 1 ]] && NO_WRITES=1

# Everything restores under --to (the new home). HOME_BASE makes expand_home
# resolve every catalog ~ root there.
export HOME_BASE="${TO%/}"

plat="$(resolve_platform)"
home="$(expand_home '~')"

MIG="$FROM/migration.yml"
LEGACY=0
if [[ ! -f "$MIG" ]]; then
  LEGACY=1
  echo "WARN: legacy backup (no migration.yml). Safe-only restore; DE/system data stays in the backup." >&2
fi

yaml_or() { local f="$1" k="$2" d="$3"; local v; v="$(yaml_get "$f" "$k")"; [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$d"; }

SRC_DISTRO="$(yaml_or "$MIG" source_distro unknown)"
SRC_FAMILY="$(yaml_or "$MIG" source_family unknown)"
SRC_DE="$(yaml_or "$MIG" source_desktop unknown)"
TGT_DISTRO="$(yaml_or "$MIG" target_distro unknown)"
TGT_FAMILY="$(yaml_or "$MIG" target_family unknown)"
TGT_DE="$(yaml_or "$MIG" target_desktop unknown)"
[[ "$TGT_FAMILY" == "unknown" || -z "$TGT_FAMILY" ]] && TGT_FAMILY="$(distro_family)"
[[ "$TGT_DE" == "unknown" || -z "$TGT_DE" ]] && TGT_DE="$(desktop_name)"
[[ "$TGT_DISTRO" == "unknown" || -z "$TGT_DISTRO" ]] && TGT_DISTRO="$(distro_id)"
ACTUAL_DE="$(desktop_name)"
ACTUAL_FAMILY="$(distro_family)"

[[ -n "$PROFILE" ]] || PROFILE="$(yaml_or "$MIG" restore_profile safe)"
[[ -n "$PROFILE" ]] || PROFILE="safe"
case "$PROFILE" in safe|same-de|verbatim) ;; *) echo "ERROR: --profile must be safe|same-de|verbatim" >&2; exit 2 ;; esac
[[ $LEGACY -eq 1 && "$PROFILE" == "verbatim" ]] && { echo "ERROR: verbatim is not allowed for a legacy backup (no migration profile)." >&2; exit 2; }
[[ $FORCE -eq 1 || "$PROFILE" == "verbatim" ]] && OVERWRITE=1 || OVERWRITE=0

target_pkg_manager() {
  case "$TGT_FAMILY" in
    debian) echo apt ;;
    arch) echo pacman ;;
    fedora) echo dnf ;;
    suse) echo zypper ;;
    *) pkg_manager ;;
  esac
}

echo "platform=$plat restore-to=$TO from=$FROM"
echo "migration: $SRC_DISTRO/$SRC_FAMILY/$SRC_DE -> $TGT_DISTRO/$TGT_FAMILY/$TGT_DE (profile=$PROFILE)"
[[ $LEGACY -eq 1 ]] && echo "legacy backup: no migration.yml"

# --- selection: the backup's own selection wins over this host's user.yml ------
BACKUP_SEL="$(yaml_or "$MIG" selection "")"
if [[ -n "$INCLUDE" ]]; then
  IDS="$(printf '%s' "$INCLUDE" | tr ',' '\n')"
  [[ -n "$PRESET" ]] && IDS="$IDS"$'\n'"$(preset_ids "$PRESET")"
elif [[ -n "$PRESET" ]]; then
  IDS="$(preset_ids "$PRESET")"
elif [[ -n "$BACKUP_SEL" ]]; then
  IDS="$(printf '%s' "$BACKUP_SEL" | tr ' ' '\n')"
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

# --- decision helpers ---------------------------------------------------------
APPLIED=(); STAGED=(); SKIPPED=(); FAILED=()
DECISION_ROWS=""

record() { # record <id> <decision> <reason>
  DECISION_ROWS="$DECISION_ROWS| $1 | $(source_policy "$1") | $(source_phase "$1") | $2: $3 |"$'\n'
}

policy_decision() { # policy_decision <id> <target-under-to>
  local id="$1" under="$2" pol
  pol="$(source_policy "$id")"
  case "$pol" in
    never) echo "skip" ;;
    manual) echo "stage" ;;
    same-de)
      if policy_allows same-de "$PROFILE" "$SRC_DE" "$TGT_DE"; then
        [[ "$under" == "yes" ]] && echo "apply" || echo "stage"
      else
        echo "stage"
      fi
      ;;
    *) [[ "$under" == "yes" ]] && echo "apply" || echo "stage" ;;
  esac
}

resolve_dir_target() {
  local id="$1" root
  root="$(catalog_field "$id" root)"
  [[ -n "$root" ]] || return 1
  if [[ "$id" == gaming_* || "$id" == browsers ]]; then
    first_existing_root "$root"
  else
    resolve_target_root "$root"
  fi
}

restore_dir() {
  local id="$1" pol="$2" target mirror stage decision
  local root; root="$(catalog_field "$id" root)"
  target="$(resolve_dir_target "$id" || true)"
  if [[ -z "$target" ]]; then
    SKIPPED+=("$id: target app not installed / no target root")
    record "$id" "skip" "no target root (install the app first)"
    return 0
  fi
  mirror="$FROM/$(catalog_field "$id" dest)"
  if [[ ! -d "$mirror" ]]; then
    SKIPPED+=("$id: no data in backup")
    record "$id" "skip" "no data in backup"
    return 0
  fi
  if path_under "$target" "$TO"; then under=yes; else under=no; fi
  decision="$(policy_decision "$id" "$under")"
  if [[ "$decision" == "skip" ]]; then
    SKIPPED+=("$id: policy $(source_policy "$id")")
    record "$id" "skip" "policy $(source_policy "$id")"
    return 0
  fi
  if [[ "$decision" == "stage" ]]; then
    stage="$TO/restore-manual/$id"
    STAGED+=("$id")
    record "$id" "stage" "policy $(source_policy "$id"), target not applied"
    [[ $NO_WRITES -eq 0 ]] && mkdir -p "$stage"
    run "stage $id -> $stage" rsync -aAX --ignore-existing "$mirror/" "$stage/"
    return 0
  fi
  APPLIED+=("$id")
  record "$id" "apply" "restore_policy=$(source_policy "$id")"
  [[ $NO_WRITES -eq 0 ]] && mkdir -p "$(dirname "$target")"
  local -a opts=(-aAX)
  [[ $OVERWRITE -eq 0 ]] && opts+=(--ignore-existing)
  run "restore $id -> $target" rsync "${opts[@]}" "$mirror/" "$target/"
}

restore_tar() {
  local id="$1" tarball target decision stage
  tarball="$(ls "$FROM/$(catalog_field "$id" dest)"*.tar.gz 2>/dev/null | head -1)"
  [[ -n "$tarball" ]] || tarball="$(find "$FROM" -path "*/$(catalog_field "$id" dest).tar.gz" 2>/dev/null | head -1)"
  if [[ -z "$tarball" ]]; then
    SKIPPED+=("$id: no tar in backup")
    record "$id" "skip" "no tar in backup"
    return 0
  fi
  target="$(resolve_target_root "$(catalog_field "$id" root)")"
  if path_under "$target" "$TO"; then under=yes; else under=no; fi
  if [[ $LEGACY -eq 1 && "$id" == "configs" ]]; then
    decision="stage"
  else
    decision="$(policy_decision "$id" "$under")"
  fi
  if [[ "$decision" == "skip" ]]; then
    SKIPPED+=("$id: policy $(source_policy "$id")")
    record "$id" "skip" "policy $(source_policy "$id")"
    return 0
  fi
  if [[ "$decision" == "stage" ]]; then
    stage="$TO/restore-manual/$id"
    STAGED+=("$id")
    if [[ $LEGACY -eq 1 && "$id" == "configs" ]]; then
      record "$id" "stage" "legacy backup: app configs staged for manual review"
    else
      record "$id" "stage" "policy $(source_policy "$id"), DE/profile gate"
    fi
    [[ $NO_WRITES -eq 0 ]] && mkdir -p "$stage"
    run "stage $id -> $stage" tar -xzf "$tarball" --skip-old-files -C "$stage" .
    [[ "$id" == "secrets" && $NO_WRITES -eq 0 ]] && chmod 700 "$stage/.ssh" "$stage/.gnupg" 2>/dev/null || true
    return 0
  fi
  APPLIED+=("$id")
  record "$id" "apply" "restore_policy=$(source_policy "$id")"
  [[ $NO_WRITES -eq 0 ]] && mkdir -p "$target"
  if [[ $OVERWRITE -eq 1 ]]; then
    run "restore $id -> $target" tar -xzf "$tarball" --overwrite -C "$target" .
  else
    run "restore $id -> $target (skip existing)" tar -xzf "$tarball" --skip-old-files -C "$target" .
  fi
  [[ "$id" == "secrets" ]] && fix_secrets_perms
}

fix_secrets_perms() {
  [[ $NO_WRITES -eq 1 ]] && return
  chmod 700 "$TO/.ssh" "$TO/.gnupg" 2>/dev/null || true
  chmod 600 "$TO"/.ssh/id_* 2>/dev/null || true
  chmod 644 "$TO"/.ssh/*.pub 2>/dev/null || true
}

restore_browsers() {
  local browser_dest name root _bex r
  browser_dest="$(catalog_field browsers dest)"
  [[ -d "$FROM/$browser_dest" ]] || { SKIPPED+=("browsers: no mirror"); return 0; }
  while IFS=$'\t' read -r name root _bex; do
    r="$(first_existing_root "$root" || true)"
    if [[ -z "$r" ]]; then
      SKIPPED+=("browser $name: install it on the target first")
      record "browsers/$name" "skip" "target browser not installed"
      continue
    fi
    local mirror="$FROM/$browser_dest/$name"
    [[ -d "$mirror" ]] || { SKIPPED+=("browser $name: no data in backup"); continue; }
    [[ $NO_WRITES -eq 0 ]] && mkdir -p "$(dirname "$r")"
    local -a opts=(-aAX)
    [[ $OVERWRITE -eq 0 ]] && opts+=(--ignore-existing)
    run "browser $name -> $r" rsync "${opts[@]}" "$mirror/" "$r/"
    APPLIED+=("browser $name")
    record "browsers/$name" "apply" "data profile only; keyring required for passwords"
  done < <(browser_rows "$plat")
}

restore_snapshot_manual() {
  local id="$1" destrel
  destrel="$(catalog_field "$id" dest)"
  case "$id" in
    packages) echo "  packages: target plan generated separately (see packages-to-install.txt)" ;;
    appimages)
      echo "  appimages: manual. Backed-up files are under $FROM/$destrel/files."
      echo "             Review appimages.tsv, then copy what you need to ~/AppImages/ and chmod +x."
      ;;
    gaming_saves)
      echo "  gaming_saves: manual. If Ludusavi backed up: ludusavi restore --path '$FROM/$destrel/ludusavi'"
      ;;
    system_files|network|virtualization|containers)
      echo "  $id: manual. Review $FROM/$destrel/README.md; restore.sh never writes /etc or hypervisor state."
      ;;
    snapshots|toolchains|audit)
      echo "  $id: informational ($FROM/$destrel/README.md / snapshot.txt)"
      ;;
    *) echo "  $id: informational ($FROM/$destrel)" ;;
  esac
  SKIPPED+=("$id: manual/informational")
  record "$id" "manual" "review backup artifacts; never auto-applied"
}

# --- package plan (generated, never auto-executed) ----------------------------
write_package_plan() {
  local src_list plan_dir list script
  src_list="$FROM/packages/native-apps.txt"
  [[ -s "$src_list" ]] || src_list="$FROM/packages/native-explicit.txt"
  if [[ ! -s "$src_list" ]]; then
    echo "  packages: no native inventory in this backup"
    return 0
  fi
  if [[ $NO_WRITES -eq 1 ]]; then
    plan_dir="$BB_PROJ_DIR/data/restore-plan"
  else
    plan_dir="$TO/packages"
  fi
  [[ $NO_WRITES -eq 0 ]] && mkdir -p "$plan_dir"
  list="$plan_dir/packages-to-install.txt"
  script="$plan_dir/install-packages.sh"
  if [[ $NO_WRITES -eq 1 ]]; then
    # The plan is the deliverable of --plan-only; write it to project data.
    mkdir -p "$plan_dir"
  fi
  cp "$src_list" "$list" 2>/dev/null || true
  {
    echo "#!/usr/bin/env bash"
    echo "# Generated by backup-ops for a $SRC_FAMILY -> $TGT_FAMILY migration."
    echo "# Review packages-to-install.txt first; names may differ across families."
    echo "set -euo pipefail"
    echo "LIST=\"\$(dirname \"\$0\")/packages-to-install.txt\""
    case "$(target_pkg_manager)" in
      apt)    echo "sudo apt install -y \$(cat \"\$LIST\")" ;;
      pacman) echo "xargs -r sudo pacman -S --needed --noconfirm < \"\$LIST\"" ;;
      dnf)    echo "sudo dnf install -y \$(cat \"\$LIST\")" ;;
      zypper) echo "sudo zypper install -y \$(cat \"\$LIST\")" ;;
      apk)    echo "xargs -r sudo apk add < \"\$LIST\"" ;;
      *)      echo "echo 'No supported package manager on this target; install manually.'" ;;
    esac
  } > "$script"
  chmod +x "$script" 2>/dev/null || true
  local flat="$FROM/packages/flatpak.txt"
  if [[ -s "$flat" ]]; then
    cp "$flat" "$plan_dir/flatpaks-to-install.txt" 2>/dev/null || true
    {
      echo "#!/usr/bin/env bash"
      echo "set -euo pipefail"
      echo "LIST=\"\$(dirname \"\$0\")/flatpaks-to-install.txt\""
      echo "xargs -r flatpak install -y flathub < \"\$LIST\""
    } > "$plan_dir/install-flatpaks.sh"
    chmod +x "$plan_dir/install-flatpaks.sh" 2>/dev/null || true
  fi
  echo "  package plan: $list"
}

# --- migration report ---------------------------------------------------------
write_migration_report() {
  local report="$BB_PROJ_DIR/data/migration-report.md" risk="low" family_note="same family" de_note="same desktop"
  [[ "$SRC_FAMILY" != "$TGT_FAMILY" ]] && { risk="high"; family_note="FAMILY CHANGE ($SRC_FAMILY -> $TGT_FAMILY): package names differ"; }
  [[ "$SRC_DE" != "$TGT_DE" ]] && { risk="high"; de_note="DESKTOP CHANGE ($SRC_DE -> $TGT_DE): desktop_env is staged, not applied"; }
  [[ $LEGACY -eq 1 ]] && { risk="high"; family_note="legacy backup: no source/target profile"; }
  {
    echo "# Migration report"
    echo
    echo "Generated: $(date -Iseconds)"
    echo
    echo "| | Source | Target |"
    echo "|---|---|---|"
    echo "| Distro | \`$SRC_DISTRO\` | \`$TGT_DISTRO\` |"
    echo "| Family | \`$SRC_FAMILY\` | \`$TGT_FAMILY\` |"
    echo "| Desktop | \`$SRC_DE\` | \`$TGT_DE\` (actual: \`$ACTUAL_DE\`) |"
    echo
    echo "**Risk:** $risk. $family_note. $de_note."
    echo "**Profile:** \`$PROFILE\`"
    [[ $LEGACY -eq 1 ]] && echo "**Legacy:** no \`migration.yml\`; only policy \`always\` sources were applied."
    echo
    echo "## Decisions"
    echo
    echo "| Source | Policy | Phase | Decision |"
    echo "|---|---|---|---|"
    printf '%s' "$DECISION_ROWS"
    echo
    echo "## Manual items"
    echo "- System files, NetworkManager profiles, VM definitions/disks, and container volumes are never auto-applied."
    echo "- Browsers restore data profiles only. Chromium passwords need the original keyring, or browser sync."
    echo "- DE configs are staged under \`restore-manual/desktop_env\` unless the desktop matches and profile is \`same-de\`."
    echo
    echo "## Package continuity"
    echo "- Inventory: \`$FROM/packages/native-explicit.txt\` (raw), \`native-apps.txt\` (filtered)."
    echo "- Target plan: \`$( [[ $NO_WRITES -eq 1 ]] && echo "$BB_PROJ_DIR/data/restore-plan" || echo "$TO/packages" )/packages-to-install.txt\`."
    echo "- Review names before running \`install-packages.sh\`; the project never installs packages automatically."
  } > "$report"
  echo "  migration report: $report"
  if [[ $NO_WRITES -eq 0 ]]; then
    mkdir -p "$TO" 2>/dev/null || true
    cp "$report" "$TO/migration-report.md" 2>/dev/null || true
    ( {
      echo "schema: 1"
      echo "date: \"$(date -Iseconds)\""
      echo "profile: \"$PROFILE\""
      echo "legacy: $LEGACY"
      echo "source_family: \"$SRC_FAMILY\""
      echo "target_family: \"$TGT_FAMILY\""
      echo "source_desktop: \"$SRC_DE\""
      echo "target_desktop: \"$TGT_DE\""
      echo "actual_desktop: \"$ACTUAL_DE\""
      echo "applied: \"${APPLIED[*]:-}\""
      echo "staged: \"${STAGED[*]:-}\""
      echo "skipped: \"${SKIPPED[*]:-}\""
      echo "failed: \"${FAILED[*]:-}\""
    } > "$TO/restore-info.yml" ) 2>/dev/null || true
  fi
}

run() { # run <desc> <cmd...>
  local desc="$1"; shift
  echo "  $desc"
  if [[ $NO_WRITES -eq 1 ]]; then printf '    %s\n' "$*"; return 0; fi
  if "$@"; then return 0; else FAILED+=("$desc"); return 1; fi
}

# ===========================================================================
# Phase order: packages first (plan), then fonts/themes, dotfiles/secrets,
# app configs/DE, browsers, data, and finally manual/system artifacts.
echo "restore phases:"
write_package_plan
while read -r phase id; do
  [[ -n "$id" ]] || continue
  kind="$(catalog_field "$id" kind)"
  label="$(catalog_field "$id" label)"
  label="${label:-$id}"
  echo "  [$phase] $id ($kind)"
  case "$kind" in
    dir) restore_dir "$id" "$(source_policy "$id")" ;;
    tar) restore_tar "$id" ;;
    drain) [[ "$id" == "browsers" ]] && restore_browsers || SKIPPED+=("$id: unsupported drain source") ;;
    snapshot) restore_snapshot_manual "$id" ;;
    *) SKIPPED+=("$id: unknown kind $kind") ;;
  esac
done < <(for id in $IDS; do printf '%s\t%s\n' "$(source_phase "$id")" "$id"; done | sort -n -k1,1 -k2,2)

write_migration_report

echo
if [[ $PLAN_ONLY -eq 1 ]]; then
  echo "PLAN-ONLY: no target files written."
elif [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY-RUN: no target files written."
elif [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "restore incomplete: $FROM -> $TO"
else
  echo "restore complete: $FROM -> $TO"
fi
[[ ${#STAGED[@]} -gt 0 ]] && { echo "staged for review: ${STAGED[*]}"; echo "  -> $TO/restore-manual/"; }
[[ ${#SKIPPED[@]} -gt 0 ]] && { echo "skipped/manual: ${SKIPPED[*]}"; }
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "RESTORE FAILED:" >&2
  printf '  - %s\n' "${FAILED[@]}" >&2
  exit 6
fi
[[ $LEGACY -eq 1 ]] && echo "WARNING: legacy backup; desktop/system data was not applied." >&2
exit 0

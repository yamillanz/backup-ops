---
name: backup-ops
description: >-
  AI home-backup and OS-migration command center. Status: open-source, cross-platform
  (Linux, Windows, macOS, WSL), fully configurable. Drives an interactive pipeline:
  `start` probes the machine, asks which folders/app configs/browser profiles/history
  to back up with typical picks pre-selected, confirms the destination drive, then
  backs up, verifies and self-heals problems during backup AND restore. One command
  to start the backup process; a restore command migrates onto any new OS (Linux,
  Windows, macOS, WSL) with browser-profile remapping. Use whenever the user wants to
  back up, migrate, restore, verify, list the backup scope, fix/heal an error,
  rehearse, or regenerate the backup catalog.
arguments: mode
user_invocable: true
user-invocable: true
argument-hint: "[start | backup | restore | verify | list | heal | drill | regen | onboard | status | probe]"
license: MIT
---

# backup-ops -- Router

backup-ops is a multi-CLI home-backup and OS-migration command center, built on the
same agent pattern as career-ops. Its engine (scripts + declarative catalog) is
**fully configurable and cross-platform**; the agent adds the intelligence layer:
it asks the right questions, then **self-heals** backup/restore problems.

The routing below is shared across supported agent CLIs.

## Invocation Notes

- CLIs with slash-command registration expose this router as `/backup-ops`.
- Interactive Codex sessions use `codex` in the repo root. Slash commands are not
  guaranteed in Codex, so ask Codex to run the same mode by name if `/backup-ops`
  is unavailable. Headless: `codex exec "prompt"`.
- In Cursor, the skill lives at `.cursor/skills/backup-ops/`.
- Routing semantics stay the same regardless of entrypoint.

Codex prompt examples that map to the same router semantics:

```text
Run the backup-ops start mode for a backup.
Run the backup-ops start mode for a restore onto this new OS.
Run the backup-ops backup mode with the full preset.
Run the backup-ops verify mode and report per-section results.
Run the backup-ops heal mode for the browser_profiles failure.
```

## Mode Routing

Determine the mode from `$mode` (or the natural-language intent):

| Input | Mode |
|-------|------|
| (empty / no args) | `discovery` — show command menu |
| `start` / "start the backup/migration process" / "let's back up" | `start` |
| `backup` / "run backup" / "back up now" | `backup` |
| `restore` / "migrate" / "put everything back" | `restore` |
| `verify` / "check the backup" | `verify` |
| `list` / "what would be backed up" / "show scope" | `list` |
| `heal` / "fix" / "there was an error" | `heal` |
| `drill` / "practice" / "rehearse" | `drill` |
| `regen` / "reprovision" / "refresh catalog" | `regen` |
| `onboard` / "set up" / "i'm new" / first run | `onboard` |
| `status` / "what's the status" | `status` |
| `probe` / "what's on this machine" | `probe` (read-only output of scripts/probe.sh) |

If not a known sub-command and doesn't match an intent: if it sounds like
backup/migrate intent → `start`; otherwise show discovery.

---

## Discovery Mode (no arguments)

```
backup-ops -- Command Center (cross-platform, configurable)

Available commands:
  /backup-ops start     → PIPELINE: probe → ask (typical picks pre-selected) →
                          confirm drive → backup → verify. "Start the backup process."
  /backup-ops backup    → Run backup with current user.yml selection (--preset/--include/--exclude)
  /backup-ops restore   → Restore onto this OS; browser paths remap per-platform
  /backup-ops verify    → Prove the backup/restore is honest (sqlite integrity, tar checksums)
  /backup-ops list      → Show the current scope without running anything
  /backup-ops heal      → Diagnose + fix + retry + escalate a failed step
  /backup-ops drill     → Rehearse backup→restore→verify in staging (zero risk)
  /backup-ops regen     → Refresh derived catalog baselines
  /backup-ops onboard   → First-run setup: build config/user.yml
  /backup-ops status    → Last run + open issues summary

Platforms: linux · windows · macos · wsl (detected automatically).  Any direction:
Linux ↔ Windows ↔ macOS. Catalog fully in config/manifest.yml.
```

---

## Output language

Before executing any mode, read `config/user.yml` if it exists and resolve
`language.output` (ISO code, default `en`). Inject before producing human-facing text:

> Write all user-facing output in `{language.output}` (reports, summaries, options,
> menu). Technical file paths and command output stay as-is.

---

## Context Loading by Mode

After determining the mode, load `modes/{mode}.md` before executing. It contains the
exact command sequences, verification gates, and the SELF-HEAL recipe.

- `start`, `backup`, `restore`, `verify`, `heal`: also load the current
  `config/manifest.yml` (catalog), `config/user.yml` (selection), `data/state.yml`.
- `drill`: loads `backup.md` + `restore.md` (`--to`/`--root` staging overrides).
- `regen`, `onboard`: read `scripts/probe.sh` output; propose catalog changes; never
  write user-layer files without approval.

### Modes delegated to subagent

For `start`/`backup`/`restore` (long, multi-part) you may dispatch a worker with the
mode file + catalog + user selection injected:

```python
Agent(
  subagent_type="general-purpose",
  prompt="[output language directive]\n\n[AGENTS.md core principles + SELF-HEAL protocol]\n\n[content of modes/{mode}.md]\n\n[config/manifest.yml sources built via: bash scripts/lib.sh && render_catalog]\n\n[config/user.yml]",
  description="backup-ops {mode}"
)
```

On completion, update `data/run-log.md` and `data/state.yml` before reporting back.
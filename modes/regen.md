# regen mode

Goal: refresh derived/agent-owned files after the catalog or the machine changed —
WITHOUT touching `config/user.yml` or `data/*` personal state.

## When to use
- "reprovision", "regen", "rebuild config"
- After installing new apps/config and wanting the wizard's proposals to reflect reality
- After editing `config/manifest.yml`

## Procedure

1. Re-scan read-only (`scripts/probe.sh`): platform, folders present, browsers
   present, drives.
2. Diff against `config/manifest.yml`:
   - A catalog source whose root is missing on this machine → suggest disabling
     for this platform (don't edit the catalog silently; record a recommendation).
   - A real folder/browser that the catalog doesn't cover → propose a catalog source
     addition (user approves the diff; never auto-write the committed file).
3. Revalidate the engine:
   ```
   bash -n scripts/*.sh
   bash scripts/backup.sh --dry-run      # still runs with the resolved selection
   ```
4. If the user edited the catalog, confirm the new version parses via
   `render_catalog`.

## Record
`data/run-log.md`; `data/state.yml` (`last_regen`).
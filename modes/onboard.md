# onboard mode

Goal: first-run setup on a fresh clone. Build `config/user.yml` (destination,
preset/selection, output language) from a probe + Q&A, then hand off to `start`.

## Trigger
`config/user.yml` missing, or user says "onboard me / set up / i'm new".

## Procedure

1. Greet (first run only):
   > "Hi — I'm backup-ops. I'll look at your machine, then ask a few questions so I
   > know what to back up and where. Most choices are pre-selected; you just confirm."

2. Run the probe (read-only) and summarize:
   ```bash
   bash scripts/probe.sh
   ```
   Read: `platform=`, `home=`, `[folders]`, `[browsers]` present/absent, `[drives]`.

3. Copy the example:
   ```bash
   cp config/user.example.yml config/user.yml
   ```

4. Ask, in order, storing answers into `config/user.yml`:
   a. Output language → `language.output` (default en; es if they reply in Spanish).
   b. Destination drive → `destination:` (show detected `[drives]` from probe).
   c. Preset → `preset: essentials` (default) or `full`/`minimal`. If they want to
      customize precisely, let them toggle individual sources and write
      `selection: [...]` (setting `preset:` to empty).
   d. Non-interactive? → `auto_confirm: true|false`.

5. Summarize the resulting selection table (from `lib.sh render_catalog` intersected
   with what probe says exists on this machine). Get explicit approval.

6. Offer a free rehearsal: `drill` mode.

## Write rules
Only `config/user.yml` and (optionally) `docs/notes.md` are written here. Never edit
the committed `config/manifest.yml` catalog. If probe reveals something uncataloged
(a new browser or config dir), propose a catalog addition for the user to approve.

## Record
`data/state.yml`: `onboarded: true`, `onboarded_at`, chosen destination/preset,
`language.output`. One `data/run-log.md` line.
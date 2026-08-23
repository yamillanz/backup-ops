# list mode

Goal: show the user exactly what backup-ops *would* back up or restore, cheaply and
with zero writes. Read-only preview.

## Behavior

1. Load catalog `config/manifest.yml` + `config/user.yml`.
2. Print the effective selection (resolve preset vs selection list) in
   `language.output` (default `en`), grouped by kind, with each source's current
   platform root and `enabled` default:

```
backup scope → <destination>
  folders/dirs:  Documents, Projects, Desktop, Pictures, Videos, Music, Public
  config+dotfiles: configs (~/.config), dotfiles, histories
  secrets:       SSH (~/.ssh) + GPG (~/.gnupg)
  browsers:      Firefox, Brave, Chrome, Edge, Opera, Vivaldi, Zen, LibreWolf (present ones)
  system state:  snapshot
```

3. Optionally run `bash scripts/backup.sh --dry-run` to show actual rsync deltas for
   `dir` sources — ask first; can be slow on large trees.
4. Highlight anything risky: missing destination, huge sources, sources present on
   disk but NOT in the selection. Do NOT modify any config here.

## Record
Read-only; may append one `data/run-log.md` line (`list: displayed scope`).
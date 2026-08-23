# restore mode

Goal: place a backed-up home back onto a (fresh) system — this is the **Omarchy 4.0
(Arch)** migration case, or any Windows/macOS→Linux move. The catalog maps every
source dest back through the CURRENT platform's roots, so a Windows backup restores
onto Linux automatically (browsers included). Verify after. SELF-HEAL at full strength.

## Preflight

1. Load catalog `config/manifest.yml` + `config/user.yml` + `data/state.yml`.
2. Locate `--from` (backup root). If unavailable/incomplete → `verify` first.
3. Detect new OS (informational): `cat /etc/os-release`; `which pacman yay apt dnf`
   (Omarchy → pacman/yay). Used only for the reinstall checklist note.
4. Default `--to` = `$HOME`; `--dry-run` first unless disabled. Home-only writes.

## Sequence (engine-driven)

Run `bash scripts/restore.sh --from <root> [--to <home>] [--dry-run] [--preset|--include|--exclude|--ask]`.

1. **dir** — reverse-rsync each `dirs/<id>/` → current platform root of that source
   (e.g. Windows-created `dirs/documents` → `$HOME/Documents` on Linux).
2. **browsers (drain)** — restore each browser's mirrored profile to its CURRENT
   platform path (e.g. Windows `User Data` → Linux `~/.var/app/com.*/...` or native).
   Version mismatch → SELF-HEAL neutral-profile rule (data files only).
3. **tar** — configs → `~/.config`; dotfiles + histories → `$HOME`; secrets → `.ssh`
   + `.gnupg` with **perms re-enforced** (dir 700, keys 600, pub 644).
4. **snapshot** — informational: hand the checklist (reinstall apps, then config).

## Verification gate

`bash scripts/verify.sh --tree <new-home> --restored`: dotfiles parse
(`zsh -n`/`bash -n`), SSH perms 600, catalog roots present, browser sqlite integrity.
Fail → `heal` → escalate. Do NOT mark done on browser failures without options.

## Cross-OS notes

- Flatpak browser apps (Brave/Chrome/Edge/Opera/Vivaldi/Zen/LibreWolf) restore into
  the same paths on Linux; reinstall matching flatpaks on Omarchy first.
- System state (`snapshot.txt`) = reinstall checklist — see `docs/migration-checklist.md`.
- GNOME (Pop) vs COSMIC (Omarchy) settings: restored `~/.config/cosmic` applies;
  GNOME-specific config is inert until that DE is installed.

## Record

`data/run-log.md` + `data/state.yml` with the detected OS and any highlighted risks.
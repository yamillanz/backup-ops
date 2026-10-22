# restore mode

Goal: place a backed-up home onto a (fresh) system across platforms/families, with
**gated** restore. The backup's `migration.yml` is authoritative; the target is
probed, and the migration report explains every decision.

## Preflight

1. Load catalog + `config/user.yml` + `data/state.yml`.
2. Locate `--from`; verify the backup first if it looks incomplete.
3. Probe the new OS (`probe.sh`): distro, family, desktop, package manager, Flatpak,
   browsers, keyring.
4. Read `migration.yml`: source family/desktop, target intent, selection, profile.
   No `migration.yml` → **legacy**: safe-only, warning, no DE/system apply. App
   configs are staged under `restore-manual/configs` instead of blindly applied,
   because an old `configs` tar may still contain desktop-environment state.
5. Default `--to` = `$HOME`. Home-only writes, except staged manual artifacts.

## Plan first

```bash
bash scripts/restore.sh --from <root> --to "$HOME" --plan-only
```

Writes no target files. It writes `data/migration-report.md` and the package plan
(under `data/restore-plan/`). Review:

- family change (`debian → fedora`): package names differ; use the plan
- desktop change (`gnome → kde`): `desktop_env` is staged, not applied
- browser install format (native vs Flatpak): install the browser first
- fonts/themes before app/DE configs
- manual sources: `/etc`, NetworkManager, VMs, containers, AppImages, saves

## Apply

```bash
bash scripts/restore.sh --from <root> --to "$HOME" [--profile safe|same-de|verbatim]
```

Default `safe`. Policies:

| Policy | Behavior |
|---|---|
| `always` | apply in phase order |
| `same-de` | apply only when source/target desktop match AND profile is `same-de` (or `verbatim`); otherwise stage |
| `manual` | stage under `<to>/restore-manual/<id>`; never write `/etc` or system paths |
| `never` | informational only |

Phases: 10 packages plan → 20 fonts/themes → 30 dotfiles/secrets → 40 app configs/DE
→ 50 browsers → 60 data → 90 system/manual.

`verbatim` is intentionally dangerous: overwrite existing files and apply DE configs
regardless of desktop. Never use it across distro families without a manual review.

## Package continuity

`restore.sh` reads `packages/native-apps.txt` (filtered) or `native-explicit.txt` and
generates:

- `packages-to-install.txt`
- `install-packages.sh` (target package manager)
- `flatpaks-to-install.txt` + `install-flatpaks.sh`

It **never executes them**. Package names differ across families; review before
running. This replaces guessing.

## Browsers

- Install the browser on the target first; restore only into an existing target root.
- Restore is data-only: History/Cookies/Bookmarks/places.sqlite/extensions.
- Chromium-variant passwords are encrypted with the system keyring. Restore
  `~/.local/share/keyrings` before the browser, or use browser sync. Without it,
  passwords will not decrypt.
- Version mismatch: restore data files into a neutral profile; let the app regenerate
  `Local State`/`Prefs`. See `heal`.

## Desktop environments

Do **not** copy DE configs across desktops. `desktop_env` is a separate tar with
policy `same-de`; on a mismatch it lands in `restore-manual/desktop_env/` for review
(dconf dump, KDE `.ini` files). Same DE still requires matching versions and the
explicit `--profile same-de`. Install fonts/themes/extensions first, then import.

## Verification gate

```bash
bash scripts/verify.sh --tree "$HOME" --restored
```

Checks dotfiles parse, SSH/keyring perms, browser sqlite, fonts when applied, DE gate,
migration report, and package plan. Fail → `heal` → escalate.

## Record

`data/run-log.md`, `data/state.yml`, `<to>/restore-info.yml`,
`<to>/migration-report.md`.

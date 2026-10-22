# clean mode — remove migration baggage before packing

Goal: avoid carrying years of caches, trash, and unused packages into the new
system. The transcript's first step is cleanup; this mode is **report-first** and
never deletes without a named action plus `--yes`.

## Rules

1. Default is read-only. Never run `rm -rf` on a home directory.
2. Never empty the trash, remove packages, or clean package caches without the
   explicit flag and `--yes`.
3. Never clean browser profiles, keyrings, dotfiles, or project directories.
4. If disk space is the problem, report the biggest offenders and offer options:
   package cache, trash, old kernels/runtimes, or narrowing the backup selection.

## Sequence

1. Report:
   ```bash
   bash scripts/clean.sh
   ```
   Read home caches/trash, package-manager caches, orphan package preview, and
   unused Flatpak runtimes. Nothing is written.

2. Present the report and ask which, if any, actions to take. Typical safe wins:
   - Package cache only: `bash scripts/clean.sh --cache --yes`
   - Orphan packages: `bash scripts/clean.sh --orphans --yes`
   - Unused Flatpak runtimes: `bash scripts/clean.sh --flatpak --yes`
   - Empty trash: `bash scripts/clean.sh --trash --yes`
   - All of the above: `bash scripts/clean.sh --all --yes`

3. After cleanup, re-run the report and then continue with `backup` or `migrate`.

## What this mode does not do

- It does not uninstall applications you still use. Review the orphan list first;
  `apt autoremove`/`pacman -Rns`/`dnf autoremove` can remove packages you expected
  to keep if they were installed as dependencies.
- It does not delete `~/.cache` wholesale; that can break running apps. The report
  shows its size so you can decide.
- It does not delete VM disks, game libraries, AppImages, or old downloads.

## Escalation

If the destination is still too small, offer concrete options: exclude `Downloads`,
`Games`, `flatpak_data`, or `vm_disks`; split the backup by source; or use a larger
drive. Record the decision in `data/state.yml`.

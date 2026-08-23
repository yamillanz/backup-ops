# Backup-Ops

Back up your whole home — files, documents, projects, app configs, dotfiles, shell
history, SSH/GPG keys, and every browser's profile + browsing history — then restore
it all onto a fresh operating system. Driven by an AI agent (Claude Code, Codex,
OpenCode, Cursor, etc.), **fully configurable**, and cross-platform (Linux, Windows,
macOS, WSL).

This guide walks through the two real journeys people use it for:

1. **The backup** — before leaving the current OS (e.g. Pop!_OS).
2. **The restore** — on the new OS (e.g. Omarchy 4.0).

Both follow the same rhythm: *probe the machine → answer a few questions (typical
picks already pre-selected) → confirm → run → verify*. If anything breaks mid-way,
the agent diagnoses the problem and asks you before doing anything destructive.

---

## Two ways to run it

- **Path A (recommended):** run it *inside your AI agent tool* — the agent asks the
  questions and self-heals problems.
- **Path B (no agent):** run the same scripts directly from a terminal.

Every step below shows Path A; the "Path B" sections show the exact script the agent
drives for you.

---

# PART 1 — The backup (on your current OS)

### Step 0 — Install the two prerequisites

Backup-Ops needs `rsync` and `sqlite3` (sqlite keeps browser history safe during the
copy):

```bash
# Pop!_OS / Ubuntu / Debian
sudo apt install -y rsync sqlite3

# Arch / Omarchy
sudo pacman -S --needed rsync sqlite3

# Fedora
sudo dnf install -y rsync sqlite

# macOS (rsync is usually preinstalled)
brew install sqlite3
```

### Step 1 — Download the project

```bash
git clone https://github.com/<you>/backup-ops.git
cd backup-ops
```

> No repo yet? Just copy the folder (e.g. `cp -r ~/Projects/backup-ops ./backup-ops`).

### Step 2 — Open your favorite agent tool

Pick any — they all read the same skill in this folder:

| Tool | How to open it |
|------|----------------|
| **OpenCode** | `opencode` in the `backup-ops/` folder |
| **Claude Code** | `claude` in the `backup-ops/` folder |
| **Codex** | `codex` in the `backup-ops/` folder |
| **Cursor** | open `backup-ops/` as a workspace |
| **Grok Build CLI** | `grok` in the `backup-ops/` folder |
| **Qwen / Copilot / Kimi** | same — open the folder and start chatting |

### Step 3 — Start the process

Run the slash command, **or** just say it in plain words — both route to the same
pipeline:

```
/backup-ops start
```

or say:

> "Start the backup process"

or in Codex (no slash commands):

```text
Run the backup-ops start mode for a backup.
```

**What happens next:** the agent runs the probe (`scripts/probe.sh`) and detects your
platform, home folder, present folders, installed browsers, and connected drives. Then
it starts asking you questions.

### Step 4 — Answer the questions

A short set of questions. **The typical answers are already pre-selected** — you mostly
just confirm:

1. **Where should the backup live?** — it lists the external drives it found; pick the
   mount path (e.g. `/media/yamillanz/BACKUP/home-backup`). Plug in the USB/NVMe drive
   first.
2. **What should be backed up?** — folders, configs, dotfiles, secrets, browsers,
   system state are pre-selected. Tweak if you want ("skip Downloads", "add Games",
   or "keep all").
3. **Output language** — so the agent talks to you in your language (default English).

Your answers are saved to `config/user.yml` (your personal file, never committed).

### Step 5 — Confirm and run

The agent shows a plan table and runs a **dry-run** preview first:

```bash
bash scripts/backup.sh --dry-run
```

Then, once you confirm, it runs for real:

```bash
bash scripts/backup.sh
```

### Step 6 — Verify

Verification is not optional. The agent runs:

```bash
bash scripts/verify.sh --tree /media/yamillanz/BACKUP/home-backup
```

and reports each section: folders, browser sqlite integrity, tar checksums, secrets.
All green = your backup is honest. **Keep the drive unplugged** until you're on the
new OS.

---

### Path B — the same backup with no agent

```bash
cp config/user.example.yml config/user.yml     # one-time setup
# edit config/user.yml: set destination + preset (or leave selection empty)
bash scripts/probe.sh                            # see what it detected
bash scripts/backup.sh --dry-run                 # preview
bash scripts/backup.sh                           # go
bash scripts/verify.sh --tree <destination>      # prove it
```

---

# PART 2 — The restore (on the new OS)

This is where you move onto the fresh system. The catalog already knows the target
paths, so a backup made on Pop!_OS (or Windows, or macOS) restores onto Omarchy 4.0
correctly — browsers included.

### Step 1 — Install the new OS

Install Omarchy 4.0 (or any Linux). Do **not** copy your files yet. The backup tool
restores your *home directory and user config* — the OS itself you install fresh.

### Step 2 — Reinstall your apps first

Your app *data* will be restored, but app *binaries* are not (that's the distro's
job). The backup captured a checklist — `system-state/snapshot.txt` — including the
flatpak list. Flatpaks are portable, so the IDs carry straight over:

```bash
flatpak install flathub com.brave.Browser com.google.Chrome com.microsoft.Edge \
  com.opera.Opera com.vivaldi.Vivaldi app.zen_browser.zen io.gitlab.librewolf-community
# ... and the rest from snapshot.txt
```

(Full checklist: `docs/migration-checklist.md`.)

### Step 3 — Download the project on the new OS

Same as before — the new machine needs the same `backup-ops/` folder:

```bash
git clone https://github.com/<you>/backup-ops.git
cd backup-ops
sudo pacman -S --needed rsync sqlite3        # Omarchy / Arch
```

### Step 4 — Open your agent tool

Same as Step 2 in Part 1 — `opencode`, `claude`, `codex`, etc., in the `backup-ops/`
folder.

### Step 5 — Start the restore process

```
/backup-ops start restore
```

or say:

> "Start the restore process — I want to put everything back."

or in Codex:

```text
Run the backup-ops start mode but it's a restore onto Omarchy.
```

### Step 6 — Answer the questions

Same rhythm, reversed:

1. **Where is the backup?** — the external drive path (`--from`).
2. **Where should it go?** — your new home (defaults to `$HOME`).
3. **What should be restored?** — everything that was in the backup, pre-selected.

### Step 7 — Confirm, run, verify

The agent dry-runs, confirms, restores, and verifies:

```bash
bash scripts/restore.sh --from /media/yamillanz/BACKUP/home-backup --dry-run
bash scripts/restore.sh --from /media/yamillanz/BACKUP/home-backup
bash scripts/verify.sh --tree ~ --restored
```

The restore-side verify checks your dotfiles still parse, your SSH keys have the right
permissions, and your browser history came back intact.

### Step 8 — Live on it for a week, then wipe the drive

Keep the backup drive until you're comfortable. Then (and only then) reformat it.

---

### Path B — the same restore with no agent

```bash
bash scripts/restore.sh --from <backup-root> --to ~ --dry-run
bash scripts/restore.sh --from <backup-root> --to ~
bash scripts/verify.sh --tree ~ --restored
```

---

## The two files you'll actually touch

Everything else is engine + agent playbooks. These two are yours:

```yaml
# config/user.yml   (personal, gitignored)
language:
  output: en            # human output language
preset: essentials      # essentials | full | minimal
selection: []           # precise list overrides preset: ["documents","projects","secrets"]
destination: "/media/yamillanz/BACKUP/home-backup"
auto_confirm: false
```

```yaml
# config/manifest.yml  (committed catalog — the configurable part)
# add/edit sources, per-platform roots, presets, browsers, exclude rules here
```

Want to back up something new (a game folder, a different browser)? Add a `source`
block to the catalog. Want to reorder or rename a preset? Edit `presets:`. That's the
whole philosophy — **configurable first, always**.

## Requirements, security, development

See [README's sibling docs](docs/) for the migration checklist, and
[CONTRIBUTING.md](CONTRIBUTING.md) for development. Quick facts: MIT licensed, no
runtime beyond bash + rsync + tar + sqlite3, secrets backed up to a `0600` tar and
restored with strict permissions, never logged, never destructive.

*Data gets configured, never hardcoded.*
# Dir Safe Mirror (Bash)

A small interactive Bash script to **mirror** one directory into another (destructive sync) or perform a **non‑destructive copy** using your choice of engine:

* **Standard**: `rm -rf` + `cp -a` (mirror) or `cp -au` (copy mode)
* **rsync**: `rsync -aH --delete --info=progress2` (mirror) or `rsync -aH --info=progress2` (copy mode)
* **rclone**: `rclone sync` (mirror) or `rclone copy` (copy mode)

It performs safety checks and can make a **backup of the destination** in `/tmp` before syncing.

---

## Features

* Engine selection: **cp**, **rsync**, or **rclone**
* **Preview** before copying: total files, total size, optional per‑file list
* **Two modes**:

  * **Mirror** (default): destination becomes an exact mirror of source (extra files at destination are removed)
  * **Copy mode** (`--copy`): non‑destructive; extra files at destination are **kept**
* Safety checks:

  * Source and destination must differ
  * Destination `/` is refused
  * Extra confirmation for “sensitive” paths (`/etc`, `/var`, `/usr`, …)
  * Detects nesting (src inside dst or dst inside src)
* Destination backup to `/tmp` using a timestamped temp directory (can be skipped)
* Graceful abort on **Ctrl+C**
* Least privilege: elevates only when required (mkdir/rm, optional installs); can be **forced off** with `--no-sudo`
* **Config file** with sane defaults, **auto‑created** on first run
* **Logging** to a file (configurable; defaults under XDG state directory)
* **Skippable steps** via `--skip` or config: `preview`, `backup`, `safety`
* **Non‑interactive paths** via `-s/--src` and `-d/--dst`; default tool via `-t/--tool`
* **Dry run** mode via `--dry-run` or config
* **Unattended runs** with `--no-confirm` (auto‑answers prompts with their default)

> If `rsync`/`rclone` are missing, the script can **offer to install** them (with your confirmation). Otherwise, pick another engine.

---

## Requirements

* **Linux** with **Bash ≥ 4.2** (uses `${var,,}` and `declare -g`)
* **GNU coreutils** (for `readlink -f`)
* **GNU find** (uses `-printf` in preview)
* Optional:

  * `rsync` for the rsync engine
  * `rclone` for the rclone engine

> macOS is not targeted (no `readlink -f` by default, older Bash).

---

## Install

Save the script as `dsm`, then make it executable:

```bash
chmod +x dsm
```

Optionally place it somewhere on your `PATH`.

---

## Configuration

**Location (auto‑created if missing):**

* Primary: `${XDG_CONFIG_HOME:-$HOME/.config}/dsm/config`
* Legacy (read if present; not auto‑created): `~/.dsm/config`

**Format:** `key=value`. Lines starting with `#` are comments. The file is created with `chmod 600`.

**Precedence:** `CLI > config > built‑in defaults`. For `skip` lists, values are **merged** (union).

**Defaults written on first run:**

```ini
# dsm configuration (auto-created)
# Keys: tool, log, skip, dry_run, no_sudo, src, dst, rsync_opts, rclone_opts, cp_opts

tool=cp
log=${XDG_STATE_HOME:-$HOME/.local/state}/dsm/dsm.log
skip=
dry_run=false
no_sudo=false
src=
dst=
rsync_opts=
rclone_opts=
cp_opts=
```

**Supported keys:**

* `tool=cp|rsync|rclone` — default engine.
* `log=/path/to/file` — append logs here (directory auto‑created). Default lives under `${XDG_STATE_HOME:-$HOME/.local/state}/dsm/dsm.log`.
* `skip=preview,backup,safety` — comma‑separated steps to skip.
* `dry_run=true|false` — run without changing anything.
* `no_sudo=true|false` — disallow privilege escalation; operations requiring it will fail.
* `src=/path` / `dst=/path` — default source/destination (non‑interactive).
* `rsync_opts=...` / `rclone_opts=...` / `cp_opts=...` — extra flags appended to the engine command.

> There is **no config key** for copy vs mirror. Use `--copy` to enable copy mode for a run.

---

## CLI overview

* `-s, --src DIR` — set source directory (non‑interactive)
* `-d, --dst DIR` — set destination directory (non‑interactive)
* `-t, --tool cp|rsync|rclone` — choose engine
* `--dry-run` — simulate actions; no changes
* `--skip preview,backup,safety` — skip steps (values merged with config)
* `--no-sudo` — never escalate privileges (sudo/doas disabled)
* `--no-backup` — skip destination backup (same as `--skip backup`)
* `--no-confirm` — answer prompts automatically with their **default** (safety prompts default to **No**)
* `--copy` — non‑destructive copy mode (keeps extra files in destination)
* `--config FILE` — use explicit config path (auto‑created if missing)
* `--log FILE` — override log file path

---

## Usage

### Interactive

```bash
./dsm
```

You will be prompted to:

1. Enter the **source** directory.
2. Enter (or create) the **destination** directory.
3. Confirm if the destination looks “sensitive”.
4. Pick the engine:

   ```
   1) Standard (cp + rm)
   2) rsync
   3) rclone
   ```

On completion, the script prints where the destination backup was saved.

> Abort at any time with **Ctrl+C**. In yes/no prompts, `q`, `quit`, or `exit` will also exit.

### Non‑interactive examples

Select source/destination and engine:

```bash
./dsm -s ./src -d ./dst -t rsync
```

Dry‑run with preview auto‑enabled, no changes applied:

```bash
./dsm --dry-run -s ./src -d ./dst -t cp
```

Skip preview and backup (safety still on):

```bash
./dsm -s ./src -d ./dst --skip preview,backup -t rclone
```

Force no privilege escalation and no interactive questions:

```bash
./dsm -s ./src -d ./dst -t rsync --no-sudo --no-confirm
```

Enable **copy mode** (keep extra files at destination):

```bash
# cp engine: non-destructive update-in-place
./dsm -s ./src -d ./dst -t cp --copy

# rsync engine: no --delete
./dsm -s ./src -d ./dst -t rsync --copy

# rclone engine: use 'rclone copy'
./dsm -s ./src -d ./dst -t rclone --copy
```

Use a custom config file:

```bash
./dsm --config /path/to/custom.cfg -s ./src -d ./dst
```

Send logs to a specific file (overrides config):

```bash
./dsm --log /var/log/dsm/run.log -s ./src -d ./dst
```

**Note:** CLI flags override the config file. `skip` values from CLI and config are merged.

---

## Preview logic

* **cp (mirror, default)**: destination is cleared before copy → preview = **all source files**.
* **cp (copy mode, `--copy`)**: non‑destructive → preview = **delta** (files where size OR mtime differs).
* **rsync / rclone**: preview = **delta** (size OR mtime differs) regardless of mode.

The preview shows:

* Count and total size **in source**
* Count and total size that **will be transferred**
* Optional per‑file list

---

## Engine behavior

| Engine     | Mirror command (simplified)                                                               | Copy‑mode command (simplified)                                                            | Notes                                                                                    |
| ---------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **cp**     | `rm -rf "$dst"/{*,.[!.]*,..?*}` → `cp -a "$src"/. "$dst"/`                                | `cp -au "$src"/. "$dst"/`                                                                 | Mirror clears destination (incl. dotfiles); copy mode updates in place and keeps extras. |
| **rsync**  | `rsync -aH --delete --info=progress2 $rsync_opts "$src"/ "$dst"/`                         | `rsync -aH --info=progress2 $rsync_opts "$src"/ "$dst"/`                                  | Copy mode omits `--delete`, so extra files at destination are preserved.                 |
| **rclone** | `rclone sync --progress --copy-links --local-no-check-updated $rclone_opts "$src" "$dst"` | `rclone copy --progress --copy-links --local-no-check-updated $rclone_opts "$src" "$dst"` | Copy mode uses `copy` instead of `sync`.                                                 |

Extra per‑engine options from the config are appended when present.

---

## Backup

Before syncing, the current destination is copied to a unique, timestamped temp directory, e.g.:

```
/tmp/<basename(dst)>.YYYYMMDDTHHMMSSmmm.XXXX
```

Example:

```
/tmp/data.20250822T203012123.Kf8s
```

Backups remain in `/tmp` until the system cleans them up. You can skip this step with `--no-backup`, `--skip backup`, or `skip=backup` in the config.

---

## Logging

If `log` is set (default: `${XDG_STATE_HOME:-$HOME/.local/state}/dsm/dsm.log`), the script appends structured lines with timestamps (UTC), selected tool, paths, preview summary, and final status. The log directory is created automatically.

---

## Exit codes

* `0` — success (or a deliberate exit via prompt)
* `1` — validation/operation error
* `130` — aborted by user (Ctrl+C)

---

## Example session

```
Enter source directory: /data/src
Enter destination directory: /data/dst
Destination is a sensitive directory: /data/dst
Do you want to continue? (y/N): y
Are you absolutely sure? (y/N): y

Choose copy tool:
1) Standard (cp + rm)
2) rsync
3) rclone
Select: 2
Selected: rsync

Preview — delta (size+mtime)
Source files:   21
Source size:    543 KB (556556 bytes)
Will transfer:  5
Transfer size:  123 KB (126000 bytes)

The task was completed successfully. Previous data backed up to: /tmp/dst.20250822T203012123.w3Qf
```

---

## Known limitations

* Linux‑only assumptions (`readlink -f`, Bash ≥ 4.2; GNU `find -printf`).
* No checksum comparison in preview (size+mtime only).
* Optional package installation is offered only when a supported package manager is detected.
* Legacy config path `~/.dsm/config` is read if present but is not auto‑created.
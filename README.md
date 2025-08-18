# Smart Mirror Copy (Bash)

A small interactive Bash script to **mirror** one directory into another using your choice of engine:

* **Standard**: `rm -rf` + `cp -a`
* **rsync**: `rsync -aH --delete --info=progress2`
* **rclone**: `rclone sync`

It performs basic safety checks and makes a **backup of the destination** in `/tmp` before syncing.

---

## Features

* Engine selection: **cp**, **rsync**, or **rclone**
* Safety checks:

  * Source and destination must differ
  * Refuse destination `/`
  * Warn for “sensitive” paths (`/etc`, `/var`, `/usr`, …)
  * Detect nesting (src inside dst or dst inside src)
* Destination backup: `/tmp/<basename(dst)>.HH:MM:SS:ms-bak`
* Graceful abort on **Ctrl+C**
* Minimal, dependency-light, interactive flow

> If `rsync`/`rclone` are not installed, the script asks you to pick another engine (no auto-installation).

---

## Requirements

* **Linux** with **Bash ≥ 4.2** (uses `${var,,}` and `declare -g`)
* **GNU coreutils** (`readlink -f`)
* Optional:

  * `rsync` for the rsync engine
  * `rclone` for the rclone engine

> macOS is not targeted (no `readlink -f` by default, older Bash).

---

## Install

Save the script as, for example, `mirror.sh`, then make it executable:

```bash
chmod +x mirror.sh
```

---

## Usage

```bash
./mirror.sh
```

You’ll be prompted to:

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

> You can **abort** at any time with **Ctrl+C**. In yes/no prompts, you can also type `q`, `quit`, or `exit`.

---

## Engine Behavior

| Engine     | Command (simplified)                                                         | Notes                                                                                                                             |
| ---------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **cp**     | `rm -rf "$dst"/*` → `cp -af "$src"/. "$dst"/`                                | Fast & simple. **Does not remove hidden files** in `$dst` that don’t exist in `$src` (because `"$dst"/*` doesn’t match dotfiles). |
| **rsync**  | `rsync -aH --delete --info=progress2 "$src"/ "$dst"/`                        | True mirror. Deletes extraneous files (including hidden), shows progress, preserves hard links.                                   |
| **rclone** | `rclone sync --progress --copy-links --local-no-check-updated "$src" "$dst"` | True mirror via rclone (local→local), with detailed progress.                                                                     |

---

## Backup

Before syncing, the current destination is copied to:

```
/tmp/<basename(dst)>.HH:MM:SS:ms-bak
```

Backups remain in `/tmp` until the system cleans them up.

---

## Exit Codes

* `0` — success (or a deliberate exit via prompt)
* `1` — validation/operation error
* `130` — aborted by user (Ctrl+C)

---

## Example Session

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

The task was completed successfully. Previous data backed up to: /tmp/dst.12:34:56:123-bak
```

---

## Known Limitations

* Linux-only assumptions (`readlink -f`, Bash ≥ 4.2).
* `cp` engine won’t remove hidden files not present in source.
* No automatic installation of `rsync`/`rclone`.

---

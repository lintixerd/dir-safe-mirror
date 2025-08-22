# Smart Mirror Copy (Bash)

A small interactive Bash script to **mirror** one directory into another using your choice of engine:

* **Standard**: `rm -rf` + `cp -a`
* **rsync**: `rsync -aH --delete --info=progress2`
* **rclone**: `rclone sync`

It performs safety checks and makes a **backup of the destination** in `/tmp` before syncing.

---

## Features

* Engine selection: **cp**, **rsync**, or **rclone**
* **Preview** before copying: total files, total size, optional per-file list
* Safety checks:

  * Source and destination must differ
  * Destination `/` is refused
  * Extra confirmation for “sensitive” paths (`/etc`, `/var`, `/usr`, …)
  * Detects nesting (src inside dst or dst inside src)
* Destination backup to `/tmp` using a timestamped temp directory
* Graceful abort on **Ctrl+C**
* Least privilege: elevates only when required (mkdir/rm, optional installs)

> If `rsync`/`rclone` are missing, the script can **offer to install** them (with your confirmation). Otherwise, pick another engine.

---

## Requirements

* **Linux** with **Bash ≥ 4.2** (uses `${var,,}` and `declare -g`)
* **GNU coreutils** (for `readlink -f`)
* Optional:

  * `rsync` for the rsync engine
  * `rclone` for the rclone engine

> macOS is not targeted (no `readlink -f` by default, older Bash).

---

## Install

Save the script as `mirror.sh`, then make it executable:

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

## Preview Logic

* **cp**: destination is cleared before copy → preview = **all source files**.
* **rsync / rclone**: preview = files where **size OR mtime** differs between `src` and `dst` (computed locally and engine-agnostic).

The preview shows:

* Count and total size **in source**
* Count and total size that **will be transferred**
* Optional per-file list

---

## Engine Behavior

| Engine     | Command (simplified)                                                         | Notes                                                                                 |
| ---------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **cp**     | `rm -rf "$dst"/{*,.[!.]*,..?*}` → `cp -a "$src"/. "$dst"/`                   | Emulates mirror by clearing destination first (**including hidden files**) then copy. |
| **rsync**  | `rsync -aH --delete --info=progress2 "$src"/ "$dst"/`                        | True mirror. Deletes extraneous files, shows progress, preserves hard links.          |
| **rclone** | `rclone sync --progress --copy-links --local-no-check-updated "$src" "$dst"` | Mirror via rclone (local→local) with progress; follows symlinks on copy.              |

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

Preview — delta (size+mtime)
Source files:   21
Source size:    543 KB (556556 bytes)
Will transfer:  5
Transfer size:  123 KB (126000 bytes)

The task was completed successfully. Previous data backed up to: /tmp/dst.20250822T203012123.w3Qf
```

---

## Known Limitations

* Linux-only assumptions (`readlink -f`, Bash ≥ 4.2).
* No checksum comparison in preview (size+mtime only).
* Optional package installation is offered only when a supported package manager is detected.

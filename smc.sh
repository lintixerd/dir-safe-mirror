#!/bin/bash
# -----------------------------------------------------------------------------
# Safe directory sync/copy helper — PREVIEW + COMMENTS (least-privilege)
#
# What this script does
#   • Interactively asks for source and destination directories
#   • Lets you choose a backend: (cp + rm), rsync, or rclone
#   • Shows a PREVIEW before copying: how many files, total size, and an
#     optional per-file list
#   • Backs up current destination to /tmp before changing anything
#   • Performs safety checks (same path, '/', nesting, sensitive dirs)
#   • Avoids persistent sudo; elevates only when strictly needed (mkdir/rm,
#     optional package installs). The copy itself runs unprivileged.
#
# Preview logic
#   • cp: destination is cleaned before copy → preview = ALL source files
#   • rsync/rclone: preview = files where size OR mtime differs between src/dst
#
# Notes
#   • Indentation uses 4 spaces
#   • Requires Bash features: [[ ... ]], declare -g, extglob, etc.
# -----------------------------------------------------------------------------

# Fail fast on errors, undefined vars, and pipeline errors
set -Eeuo pipefail

# Restrict word splitting to newlines/tabs only
IFS=$'\n\t'

# Enable bash extended globs (used for trimming and hidden-file patterns)
shopt -s extglob

# ------------------------------- CLI args (help & stubs) -------------------------------
# NOTE: -h/--help, --version, and --dry-run are functional. All other flags are
# recognized but NOT IMPLEMENTED and are ignored. No behavior changes are made.
SCRIPT_NAME="${0##*/}"
VERSION="0.3.0"
DRY_RUN=0
declare -a ARGS_UNIMPL=()

print_help(){
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Safe directory sync/copy helper — PREVIEW + COMMENTS (least-privilege)

Options:
  -h, --help            Show this help and exit.
  --version             Print version and exit.
  --dry-run             Run in no-change mode: do not create/modify/delete anything,
                        skip package updates/installs, preview runs automatically,
                        and there is no proceed prompt.

  --copy                [NOT IMPLEMENTED] Non-interactive copy using current/defaults.
  --config FILE         [NOT IMPLEMENTED] Load options from a config file.
  -t, --tool TOOL       [NOT IMPLEMENTED] Preselect backend: cp | rsync | rclone.
  -s, --src DIR         [NOT IMPLEMENTED] Source directory path.
  -d, --dst DIR         [NOT IMPLEMENTED] Destination directory path.
  --skip STEPS          [NOT IMPLEMENTED] Comma-separated steps to skip:
                        preview,backup,safety

Additional (stubs):
  --no-sudo             [NOT IMPLEMENTED] Disallow any privilege escalation.
  --no-backup           [NOT IMPLEMENTED] Do not create the /tmp backup of destination.
  --no-confirm          [NOT IMPLEMENTED] Assume safe defaults without prompting.
  --log FILE            [NOT IMPLEMENTED] Append actions to FILE.

Notes:
  • All flags except -h/--help, --version, and --dry-run are placeholders and currently do nothing.
EOF
}

print_version(){
    echo "$SCRIPT_NAME $VERSION"
}

parse_args(){
    while (( $# )); do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            --version)
                print_version
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --copy|--no-sudo|--no-backup|--no-confirm|--log)
                ARGS_UNIMPL+=("$1")
                # consume value for flags that expect one
                if [[ "$1" == "--log" ]]; then
                    if [[ $# -ge 2 && "$2" != -* ]]; then ARGS_UNIMPL+=("$2"); shift; fi
                fi
                ;;
            --config|--skip|-t|--tool|-s|--src|-d|--dst)
                ARGS_UNIMPL+=("$1")
                if [[ $# -ge 2 && "$2" != -* ]]; then ARGS_UNIMPL+=("$2"); shift; fi
                ;;
            --*)  # any other long option: record as stub
                ARGS_UNIMPL+=("$1")
                if [[ $# -ge 2 && "$2" != -* ]]; then ARGS_UNIMPL+=("$2"); shift; fi
                ;;
            *)    # positional arguments (not used): record as stub
                ARGS_UNIMPL+=("$1")
                ;;
        esac
        shift
    done
}

# --------------------------- Error/Signal handlers ---------------------------
# Print failing line/command to help with debugging
on_err(){
    echo
    echo "Error (line $LINENO): $BASH_COMMAND" >&2
}

# Graceful abort on Ctrl+C / termination
on_int(){
    echo
    echo "Aborted by user."
    exit 130
}

trap on_err ERR
trap on_int INT TERM

# ------------------------------- Privileges ---------------------------------
# We do NOT keep sudo creds alive; we only attempt elevation when needed.
# If sudo/doas is present, it will prompt on first privileged operation.
SUDO=""
setup_sudo(){
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        return 0
    fi
    if command -v doas >/dev/null 2>&1; then
        SUDO="doas"
        return 0
    fi
    SUDO=""  # no helper available; privileged ops will fail with a message
}

# mkdir_safe <path>
#   Create directory, elevating only if parent is not writable
mkdir_safe(){
    local target="$1" parent
    parent=$(dirname -- "$target")
    if [[ -w "$parent" ]]; then
        mkdir -p -- "$target"
    else
        if [[ -n "$SUDO" ]]; then
            $SUDO mkdir -p -- "$target"
        else
            echo "Cannot create '$target' (no permission and no sudo/doas)." >&2
            exit 1
        fi
    fi
}

# rm_tree_contents_safe <dir>
#   Remove ALL contents of a directory (including dotfiles), elevating only if
#   the directory is not writable by the current user.
rm_tree_contents_safe(){
    local dir="$1"
    (
        shopt -s dotglob nullglob
        if [[ -w "$dir" ]]; then
            rm -rf -- "$dir"/{*,.[!.]*,..?*} || true
        else
            if [[ -n "$SUDO" ]]; then
                $SUDO rm -rf -- "$dir"/{*,.[!.]*,..?*} || true
            else
                echo "Cannot clean '$dir' (no permission and no sudo/doas)." >&2
                exit 1
            fi
        fi
    )
}

# ---------------------------- Package management ----------------------------
# Detect a package manager and build helper commands:
#   PKG_UPDATE   – refresh package metadata (run at most once per session)
#   PKG_INSTALL  – install packages, appending the names we pass in
PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""; PKG_UPDATED=0

detect_pkg_manager(){
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_UPDATE="${SUDO:+$SUDO }apt-get update -qq"
        PKG_INSTALL="${SUDO:+$SUDO }env DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v apt >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_UPDATE="${SUDO:+$SUDO }apt update -qq"
        PKG_INSTALL="${SUDO:+$SUDO }env DEBIAN_FRONTEND=noninteractive apt install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        PKG_UPDATE="${SUDO:+$SUDO }dnf -y makecache"
        PKG_INSTALL="${SUDO:+$SUDO }dnf -y install"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        PKG_UPDATE="${SUDO:+$SUDO }yum -y makecache"
        PKG_INSTALL="${SUDO:+$SUDO }yum -y install"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
        PKG_UPDATE="${SUDO:+$SUDO }zypper --non-interactive refresh"
        PKG_INSTALL="${SUDO:+$SUDO }zypper --non-interactive install --no-confirm"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
        PKG_UPDATE="${SUDO:+$SUDO }pacman -Sy --noconfirm"
        PKG_INSTALL="${SUDO:+$SUDO }pacman -S --noconfirm --needed"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_UPDATE=":"   # Alpine: refresh during install with --no-cache
        PKG_INSTALL="${SUDO:+$SUDO }apk add --no-cache"
    elif command -v brew >/dev/null 2>&1; then
        PKG_MGR="brew"
        PKG_UPDATE="brew update"
        PKG_INSTALL="brew install"
    fi
}

# Ask once whether to refresh metadata (useful for apt/dnf/yum)
pkg_update_once(){
    [[ -z "$PKG_UPDATE" ]] && return 0
    if (( PKG_UPDATED == 0 )); then
        if (( DRY_RUN )); then
            echo "DRY-RUN: skipping package metadata update."
            PKG_UPDATED=1
            return 0
        fi
        if yesno "Update package lists now? (Y/n): " Y; then
            eval "$PKG_UPDATE"
        fi
        PKG_UPDATED=1
    fi
}

# ensure_installed <pkg> [<pkg>...]
#   Try to install packages using the detected manager. If none, fail fast.
ensure_installed(){
    if (( DRY_RUN )); then
        echo "DRY-RUN: would install: $*"
        return 0
    fi
    if [[ -z "$PKG_INSTALL" ]]; then
        echo "Cannot install packages automatically (no pkg manager or no sudo/doas)." >&2
        return 1
    fi
    pkg_update_once
    # shellcheck disable=SC2086 – we intentionally expand args here
    eval "$PKG_INSTALL" $*
}

# ------------------------------- UI helpers ---------------------------------
# yesno "<prompt>" <DEFAULT>
#   Ask a yes/no question repeatedly; default applies on empty input.
yesno(){
    local message="$1" default="$2" answer
    while true; do
        read -rp "$message" answer || true
        [[ -z "${answer:-}" ]] && answer="$default"
        # trim + lowercase
        answer="${answer##*( )}"; answer="${answer%%*( )}"; answer="${answer,,}"
        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            q|quit|exit) echo "Exiting..."; exit 0 ;;
            *) echo "Choose Y or N" ;;
        esac
    done
}

# path_abs "<path>"
#   Compute absolute path without requiring it to exist (used for --dry-run).
path_abs(){
    local p="$1"
    if [[ "$p" == /* ]]; then
        printf '%s\n' "$p"
    else
        printf '%s\n' "$PWD/$p"
    fi
}

# choose_dir "<label>" <suffix> [create]
#   Prompt until an existing dir is given (or create it when allowed). On success
#   defines a global variable absolute_<suffix> that stores the canonical path.
choose_dir(){
    local message="$1" type="$2" create="${3-}" answer resolved
    while true; do
        read -rp "Enter $message: " answer || true
        if [[ -d "${answer:-}" ]]; then
            resolved=$(readlink -f -- "$answer"); declare -g "absolute_${type}=$resolved"; return 0
        fi
        if [[ -n "$create" ]]; then
            if (( DRY_RUN )); then
                echo "DRY-RUN: directory does not exist and will not be created: $answer"
                resolved=$(path_abs "$answer"); declare -g "absolute_${type}=$resolved"
                echo "Using intended path for preview: $resolved"
                return 0
            fi
            if yesno "This directory doesn't exist... Create it? (Y/n): " Y; then
                mkdir_safe "$answer"
                resolved=$(readlink -f -- "$answer"); declare -g "absolute_${type}=$resolved"
                echo "Directory created successfully."; return 0
            fi
        else
            echo "This directory doesn't exist... Input a correct path"; echo
        fi
    done
}

# ------------------------------ Preview helpers -----------------------------
# Portable stat helpers (GNU/BSD)
stat_bytes(){  # print file size in bytes
    stat -c %s -- "$1" 2>/dev/null || stat -f %z -- "$1"
}
stat_mtime(){  # print mtime (epoch seconds)
    stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1"
}

# Build list of all source files with sizes (relative paths)
# stdout: "<size>\t<relative_path>"
build_src_list(){
    ( cd "$absolute_src" && find . -type f -printf '%s\t%P\n' )
}

# Generic delta builder (backend-agnostic for rsync/rclone):
# - Includes files that are new or changed in src vs dst (size OR mtime differ)
# - stdout: "<size>\t<relative_path>"
build_delta_list_generic(){
    ( cd "$absolute_src" && find . -type f -print0 ) |
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        src_f="$absolute_src/$rel"
        dst_f="$absolute_dst/$rel"

        ssz="$(stat_bytes "$src_f" 2>/dev/null || echo 0)"
        if [[ ! -f "$dst_f" ]]; then
            printf '%s\t%s\n' "$ssz" "$rel"
        else
            dsz="$(stat_bytes "$dst_f" 2>/dev/null || echo -1)"
            smt="$(stat_mtime "$src_f" 2>/dev/null || echo 0)"
            dmt="$(stat_mtime "$dst_f" 2>/dev/null || echo 0)"
            if [[ "$ssz" != "$dsz" || "$smt" -ne "$dmt" ]]; then
                printf '%s\t%s\n' "$ssz" "$rel"
            fi
        fi
    done
}

# Human-readable bytes
hr_bytes(){
    local b=$1 d=0 s=(B KB MB GB TB PB EB ZB YB)
    while (( b >= 1024 && d < ${#s[@]}-1 )); do b=$(( b/1024 )); d=$(( d+1 )); done
    echo "$b ${s[$d]}"
}

# Print preview summary and optionally list files
# src_tmp/delta_tmp must contain "<size>\t<path>" lines
preview_print_summary(){
    local src_tmp="$1" delta_tmp="$2" title="$3" src_count src_size delta_count delta_size

    src_count=$(wc -l < "$src_tmp" | tr -d ' ')
    src_size=$(awk -F '\t' '{s+=$1} END{print s+0}' "$src_tmp")

    delta_count=$(wc -l < "$delta_tmp" | tr -d ' ')
    delta_size=$(awk -F '\t' '{s+=$1} END{print s+0}' "$delta_tmp")

    echo
    echo "Preview — $title"
    echo "Source files:   $src_count"
    echo "Source size:    $(hr_bytes "$src_size") ($src_size bytes)"
    echo "Will transfer:  $delta_count"
    echo "Transfer size:  $(hr_bytes "$delta_size") ($delta_size bytes)"

    if (( delta_count > 0 )); then
        if yesno "Show list of files to transfer? (y/N): " N; then
            if command -v less >/dev/null 2>&1 && [[ -t 1 ]]; then
                cut -f2- "$delta_tmp" | less -R
            else
                cut -f2- "$delta_tmp"
            fi
        fi
    fi
}

# Build and show preview
run_preview(){
    local force_preview=0
    (( DRY_RUN )) && force_preview=1

    if (( ! force_preview )); then
        if ! yesno "Preview copy plan first? (Y/n): " Y; then
            return 0
        fi
    fi

    local src_tmp delta_tmp title
    src_tmp=$(mktemp)
    delta_tmp=$(mktemp)

    build_src_list > "$src_tmp"
    case "$SELECTED_TOOL" in
        cp)
            # cp will clear destination ⇒ everything from src will be copied
            build_src_list > "$delta_tmp"; title="full copy from source" ;;
        *)
            # rsync/rclone: backend-agnostic size+mtime delta
            build_delta_list_generic > "$delta_tmp"; title="delta (size+mtime)" ;;
    esac

    preview_print_summary "$src_tmp" "$delta_tmp" "$title"

    rm -f "$src_tmp" "$delta_tmp"

    # In dry-run: no proceed prompt
    if (( DRY_RUN )); then
        return 0
    fi

    yesno "Proceed with copy? (Y/n): " Y || { echo "Aborted before copy."; exit 0; }
}

# ------------------------------ Tool selection ------------------------------
SELECTED_TOOL=""

# cp backend (coreutils)
cp_tool(){
    if command -v cp >/dev/null 2>&1 && command -v rm >/dev/null 2>&1; then
        SELECTED_TOOL="cp"; echo "Selected: Standard (rm+cp)"; return 0
    fi
    echo "cp or rm not found."
    if (( DRY_RUN )); then
        echo "DRY-RUN: would install coreutils."
        SELECTED_TOOL="cp"; echo "Selected: Standard (rm+cp)"; return 0
    fi
    if yesno "Install coreutils now? (Y/n): " Y; then
        ensure_installed coreutils || return 1
        SELECTED_TOOL="cp"; echo "Selected: Standard (rm+cp)"; return 0
    fi
    echo "Not installing; choose another tool."; return 1
}

# rsync backend
rsync_tool(){
    if ! command -v rsync >/dev/null 2>&1; then
        if (( DRY_RUN )); then
            echo "DRY-RUN: would install rsync."
            SELECTED_TOOL="rsync"; echo "Selected: rsync"; return 0
        fi
        if yesno "rsync is not installed. Install it now? (Y/n): " Y; then
            ensure_installed rsync || return 1
        else
            echo "Not installing; choose another tool."; return 1
        fi
    fi
    SELECTED_TOOL="rsync"; echo "Selected: rsync"; return 0
}

# rclone backend
rclone_tool(){
    if ! command -v rclone >/dev/null 2>&1; then
        if (( DRY_RUN )); then
            echo "DRY-RUN: would install rclone."
            SELECTED_TOOL="rclone"; echo "Selected: rclone"; return 0
        fi
        if yesno "rclone is not installed. Install it now? (Y/n): " Y; then
            ensure_installed rclone || return 1
        else
            echo "Not installing; choose another tool."; return 1
        fi
    fi
    SELECTED_TOOL="rclone"; echo "Selected: rclone"; return 0
}

# Minimal interactive picker for the backend
choose_tool(){
    local default="$1" choice
    while true; do
        echo "Choose copy tool:"; echo "1) Standard (cp + rm)"; echo "2) rsync"; echo "3) rclone"
        read -rp "Select: " choice || true
        [[ -z "${choice:-}" ]] && choice=$default
        choice="${choice##*( )}"; choice="${choice%%*( )}"
        case "$choice" in
            1) cp_tool && return 0 ;;
            2) rsync_tool && return 0 ;;
            3) rclone_tool && return 0 ;;
            *) echo "-----------"; echo "Enter number from 1 to 3"; echo ;;
        esac
    done
}

# ------------------------------- Main routine -------------------------------
main(){
    # 0) Parse CLI flags — -h/--help, --version, --dry-run work; others are stubs
    parse_args "$@"
    if (( ${#ARGS_UNIMPL[@]} > 0 )); then
        echo "Note: the following CLI options/args are recognized but NOT IMPLEMENTED and will be ignored:"
        printf '  %q\n' "${ARGS_UNIMPL[@]}"
        echo
    fi

    # 1) Setup privilege helper (no keepalive) and detect package manager
    setup_sudo
    detect_pkg_manager

    # 2) Ask for source/destination; offer to create destination
    choose_dir "source directory" src
    choose_dir "destination directory" dst create

    echo

    # 3) Safety checks before touching anything
    #    3a) Same path
    if [[ "$absolute_src" == "$absolute_dst" ]]; then
        echo "Source and destination are the same. Aborting..." >&2; echo; exit 1
    fi
    #    3b) Destination MUST NOT be '/'
    if [[ "$absolute_dst" == "/" ]]; then
        echo "Destination path is '/'. Aborting..." >&2; echo; exit 1
    fi
    #    3c) Nesting in either direction leads to destructive surprises
    if [[ "$absolute_src/" == "$absolute_dst"/* || "$absolute_dst/" == "$absolute_src"/* ]]; then
        echo "Source and destination are nested. Aborting." >&2; echo; exit 1
    fi
    #    3d) Extra confirmation for sensitive single-component dirs
    if [[ "$absolute_dst" =~ ^/(etc|home|var|bin|usr|lib|opt|tmp|srv|dev|mnt|media|proc|run|sys)(/)?$ ]]; then
        echo "Destination is a sensitive directory: $absolute_dst"
        yesno "Do you want to continue? (y/N): " N || { echo "Aborted..."; exit 1; }
        yesno "Are you absolutely sure? (y/N): " N || { echo "Aborted..."; exit 1; }
    fi

    # 4) Pick backend (default 1 => cp + rm)
    choose_tool 1

    # 5) PREVIEW — show what will be copied and how much
    run_preview

    # In dry-run mode, stop here (no backup, no copy)
    if (( DRY_RUN )); then
        echo "DRY-RUN: no changes made."
        exit 0
    fi

    # 6) Backup existing destination to /tmp (if it exists)
    local backup="(none)"
    if [[ -e "$absolute_dst" ]]; then
        backup=$(mktemp -d "/tmp/$(basename -- "$absolute_dst").$(date +%Y%m%dT%H%M%S%3N).XXXX")
        cp -a -- "$absolute_dst"/. "$backup"/
    fi

    # 7) Execute the chosen strategy
    case "$SELECTED_TOOL" in
        rsync)
            # -a : archive (recursive, preserve perms/times/etc.)
            # -H : preserve hard links
            # --delete : make dst mirror src (remove extraneous files)
            # --info=progress2 : progress bar for the whole transfer
            rsync -aH --delete --info=progress2 -- "$absolute_src"/ "$absolute_dst"/
            ;;
        rclone)
            # 'sync' makes dst exactly match src; --copy-links follows symlinks
            # --local-no-check-updated optimizes local copies
            rclone sync --progress --copy-links --local-no-check-updated -- "$absolute_src" "$absolute_dst"
            ;;
        cp|*)
            # Emulate "sync": clear destination first (incl. dotfiles), then copy
            rm_tree_contents_safe "$absolute_dst"
            cp -a -- "$absolute_src"/. "$absolute_dst"/
            ;;
    esac

    echo "The task was completed successfully. Previous data backed up to: $backup"
    echo
}

# ------------------------------- Entrypoint ---------------------------------
main "$@"
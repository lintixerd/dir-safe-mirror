#!/bin/bash
# -----------------------------------------------------------------------------
# Safe directory sync/copy helper
# - Lets you choose a source and destination directory interactively
# - Supports three backends: (cp + rm), rsync, rclone
# - Makes a backup of the destination into /tmp before modifying it
# - Performs safety checks: same path, root path, nesting, sensitive dirs
# - Can elevate via sudo/doas and install missing tools via the system pkg mgr
#
# Notes
# - Indentation uses 4 spaces (spaces, not literal tab characters)
# - Requires Bash (for 'declare -g', 'shopt', '[[ ... ]]', etc.)
# -----------------------------------------------------------------------------

# Fail hard on errors, undefined vars, and pipeline errors
set -Eeuo pipefail

# Tighter word splitting rules
IFS=$'\n\t'

# Enable extended globs for trimming (e.g., '*( )')
shopt -s extglob

# --------------------------- Error/Signal handlers ---------------------------
# Print the failing line and command when an error occurs
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

# Keepalive background sudo process PID (if started)
SUDO_KEEPALIVE_PID=""

# ------------------------------- Privileges ---------------------------------
# setup_sudo
# - Detects whether we are root, have sudo or doas, and configures the SUDO cmd
# - If a TTY is present, acquires sudo creds and keeps them alive in background
setup_sudo(){
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            SUDO="sudo -n"
        else
            if [[ -t 0 ]]; then
                echo "Elevated privileges are required. You'll be prompted for your password."
                sudo -v || { echo "Cannot obtain sudo credentials."; exit 1; }
                ( while true; do sudo -n true; sleep 60; done ) 2>/dev/null &
                SUDO_KEEPALIVE_PID=$!
                # Ensure we kill the keepalive on any exit
                trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
                SUDO="sudo"
            else
                echo "Error: need privileges but no TTY to prompt; re-run with sudo." >&2
                exit 1
            fi
        fi
        return 0
    fi

    if command -v doas >/dev/null 2>&1; then
        if doas -n true 2>/dev/null; then
            SUDO="doas -n"
        else
            SUDO="doas"
        fi
        return 0
    fi

    echo "Error: not root and neither 'sudo' nor 'doas' found. Re-run as root." >&2
    exit 1
}

# as_root
# - Thin wrapper to run a command with our configured privilege helper
as_root(){
    ${SUDO:-} "$@"
}

# ---------------------------- Package management ----------------------------
# Globals populated by detect_pkg_manager()
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""

# detect_pkg_manager
# - Detects host package manager and prepares update/install commands
# - Never uses sudo for Homebrew (brew)
# - Uses noninteractive flags where sensible
#
# Exposes:
#   PKG_MGR     - name (apt, dnf, yum, zypper, pacman, apk, brew)
#   PKG_UPDATE  - command to refresh package metadata
#   PKG_INSTALL - command to install packages (expects pkgnames appended)

detect_pkg_manager(){
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_UPDATE="${SUDO:-} apt-get update -qq"
        PKG_INSTALL="${SUDO:-} env DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v apt >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_UPDATE="${SUDO:-} apt update -qq"
        PKG_INSTALL="${SUDO:-} env DEBIAN_FRONTEND=noninteractive apt install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        PKG_UPDATE="${SUDO:-} dnf -y makecache"
        PKG_INSTALL="${SUDO:-} dnf -y install"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        PKG_UPDATE="${SUDO:-} yum -y makecache"
        PKG_INSTALL="${SUDO:-} yum -y install"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
        PKG_UPDATE="${SUDO:-} zypper --non-interactive refresh"
        PKG_INSTALL="${SUDO:-} zypper --non-interactive install --no-confirm"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
        PKG_UPDATE="${SUDO:-} pacman -Sy --noconfirm"
        PKG_INSTALL="${SUDO:-} pacman -S --noconfirm --needed"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_UPDATE=":"   # Alpine refreshes on install with --no-cache
        PKG_INSTALL="${SUDO:-} apk add --no-cache"
    elif command -v brew >/dev/null 2>&1; then
        PKG_MGR="brew"
        PKG_UPDATE="brew update"
        PKG_INSTALL="brew install"
    else
        PKG_MGR=""
        PKG_UPDATE=""
        PKG_INSTALL=""
    fi
}

# pkg_update_once
# - Asks the user whether to refresh package metadata; ensures it's run at most once
PKG_UPDATED=0
pkg_update_once(){
    [[ -z "$PKG_UPDATE" ]] && return 0
    if (( PKG_UPDATED == 0 )); then
        if yesno "Update package lists now? (Y/n): " Y; then
            eval "$PKG_UPDATE"
        fi
        PKG_UPDATED=1
    fi
}

# ensure_installed <pkg> [<pkg>...]
# - Installs the given packages using the detected package manager
# - If we cannot detect a package manager, we fail fast
ensure_installed(){
    if [[ -z "$PKG_INSTALL" ]]; then
        echo "Cannot install packages automatically: no supported package manager detected." >&2
        return 1
    fi
    pkg_update_once
    # shellcheck disable=SC2086  # we want word splitting of pkgs here
    eval "$PKG_INSTALL" $*
}

# ------------------------------- UI helpers ---------------------------------
# yesno "<prompt>" <DEFAULT>
# - Repeatedly prompts the user for Y/N, with default on empty input
# - Accepts: Y, YES, N, NO (case-insensitive). Also 'q'/'quit'/'exit' to abort.
yesno(){
    local message="$1" default="$2" answer
    while true; do
        read -rp "$message" answer || true
        [[ -z "${answer:-}" ]] && answer="$default"

        # Trim spaces and lowercase (requires extglob)
        answer="${answer##*( )}"
        answer="${answer%%*( )}"
        answer="${answer,,}"

        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            q|quit|exit) echo "Exiting..."; exit 0 ;;
            *) echo "Choose Y or N" ;;
        esac
    done
}

# choose_dir "<human label>" <var_suffix> [create]
# - Prompts for a directory path until it exists (or creates it if allowed)
# - On success, sets global var: absolute_<var_suffix> with canonicalized path
choose_dir(){
    local message="$1" type="$2" create="${3-}" answer resolved
    while true; do
        read -rp "Enter $message: " answer || true
        if [[ -d "${answer:-}" ]]; then
            resolved=$(readlink -f -- "$answer")
            declare -g "absolute_${type}=$resolved"
            return 0
        fi

        if [[ -n "$create" ]]; then
            if yesno "This directory doesn't exist... Create it? (Y/n): " Y; then
                as_root mkdir -p -- "$answer"
                resolved=$(readlink -f -- "$answer")
                declare -g "absolute_${type}=$resolved"
                echo "Directory created successfully."
                return 0
            fi
        else
            echo "This directory doesn't exist... Input a correct path"
            echo
        fi
    done
}

# ------------------------------ Tool selection ------------------------------
SELECTED_TOOL=""

# cp_tool
# - Uses built-in cp+rm (from coreutils). If missing, offers to install "coreutils".
cp_tool(){
    if command -v cp >/dev/null 2>&1 && command -v rm >/dev/null 2>&1; then
        SELECTED_TOOL="cp"
        echo "Selected: Standard (rm+cp)"
        return 0
    fi

    echo "cp or rm not found."
    if yesno "Install coreutils now? (Y/n): " Y; then
        ensure_installed coreutils || return 1
        SELECTED_TOOL="cp"
        echo "Selected: Standard (rm+cp)"
        return 0
    fi

    echo "Not installing; choose another tool."
    return 1
}

# rsync_tool
# - Uses rsync; installs it if missing and user agrees.
rsync_tool(){
    if ! command -v rsync >/dev/null 2>&1; then
        if yesno "rsync is not installed. Install it now? (Y/n): " Y; then
            ensure_installed rsync || return 1
        else
            echo "Not installing; choose another tool."
            return 1
        fi
    fi
    SELECTED_TOOL="rsync"
    echo "Selected: rsync"
    return 0
}

# rclone_tool
# - Uses rclone; installs it if missing and user agrees.
rclone_tool(){
    if ! command -v rclone >/dev/null 2>&1; then
        if yesno "rclone is not installed. Install it now? (Y/n): " Y; then
            ensure_installed rclone || return 1
        else
            echo "Not installing; choose another tool."
            return 1
        fi
    fi
    SELECTED_TOOL="rclone"
    echo "Selected: rclone"
    return 0
}

# choose_tool <default_number>
# - Interactive menu to pick the backend tool
choose_tool(){
    local default="$1" choice
    while true; do
        echo "Choose copy tool:"
        echo "1) Standard (cp + rm)"
        echo "2) rsync"
        echo "3) rclone"
        read -rp "Select: " choice || true
        [[ -z "${choice:-}" ]] && choice=$default

        # Trim spaces
        choice="${choice##*( )}"
        choice="${choice%%*( )}"

        case "$choice" in
            1)  cp_tool    && return 0 ;;
            2)  rsync_tool && return 0 ;;
            3)  rclone_tool&& return 0 ;;
            *)  echo "-----------"; echo "Enter number from 1 to 3"; echo ;;
        esac
    done
}

# ------------------------------- Main routine -------------------------------
main(){
    setup_sudo
    detect_pkg_manager

    # 1) Ask user for source & destination (create dest if needed)
    choose_dir "source directory" src
    choose_dir "destination directory" dst create

    echo

    # 2) Safety checks
    # 2a) Same path check
    if [[ "$absolute_src" == "$absolute_dst" ]]; then
        echo "Source and destination are the same. Aborting..." >&2
        echo
        exit 1
    fi

    # 2b) Destination is root path
    if [[ "$absolute_dst" == "/" ]]; then
        echo "Destination path is '/'. Aborting..." >&2
        echo
        exit 1
    fi

    # 2c) Nesting (src in dst or dst in src)
    if [[ "$absolute_src/" == "$absolute_dst"/* || "$absolute_dst/" == "$absolute_src"/* ]]; then
        echo "Source and destination are nested. Aborting." >&2
        echo
        exit 1
    fi

    # 2d) Sensitive directories (like /etc, /var, ...)
    if [[ "$absolute_dst" =~ ^/(etc|home|var|bin|usr|lib|opt|tmp|srv|dev|mnt|media|proc|run|sys)(/)?$ ]]; then
        echo "Destination is a sensitive directory: $absolute_dst"
        yesno "Do you want to continue? (y/N): " N || { echo "Aborted..."; exit 1; }
        yesno "Are you absolutely sure? (y/N): " N || { echo "Aborted..."; exit 1; }
    fi

    # 3) Pick a tool (default: 1 => cp + rm)
    choose_tool 1

    # 4) Backup existing destination to /tmp
    local backup
    if [[ -e "$absolute_dst" ]]; then
        # Create a unique backup dir and copy the current destination contents into it
        backup=$(mktemp -d "/tmp/$(basename -- "$absolute_dst").$(date +%Y%m%dT%H%M%S%3N).XXXX")
        cp -a -- "$absolute_dst"/. "$backup"/
    else
        backup="(none)"
    fi

    # 5) Execute the chosen sync/copy strategy
    case "$SELECTED_TOOL" in
        rsync)
            # -a  : archive mode (recursive, preserves attrs)
            # -H  : preserve hard links
            # --delete : make dst mirror src (remove extraneous files from dst)
            # --info=progress2 : nice progress display
            rsync -aH --delete --info=progress2 -- "$absolute_src"/ "$absolute_dst"/
            ;;
        rclone)
            # sync : make dst exactly match src (deletes extras)
            # --copy-links : follow symlinks and copy the pointed-to files
            # --local-no-check-updated : speed up local copies
            rclone sync --progress --copy-links --local-no-check-updated -- "$absolute_src" "$absolute_dst"
            ;;
        cp|*)
            # For cp, we emulate a "sync" by clearing the destination first (incl. dotfiles),
            # then copying the source contents.
            (
                shopt -s dotglob nullglob
                as_root rm -rf -- "$absolute_dst"/{*,.[!.]*,..?*} || true
            )
            cp -a -- "$absolute_src"/. "$absolute_dst"/
            ;;
    esac

    echo "The task was completed successfully. Previous data backed up to: $backup"
    echo
}

# ------------------------------- Entrypoint ---------------------------------
main "$@"

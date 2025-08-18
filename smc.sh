#!/bin/bash
# Catch error and word splitting limitation
set -Eeuo pipefail
IFS=$'\n\t'
on_err(){ echo; echo "Error (line $LINENO): $BASH_COMMAND" >&2; }
on_int(){ echo; echo "Aborted by user."; exit 130; }
trap on_err ERR
trap on_int INT TERM


function yesno(){
	local message="$1" default="$2" answer
	while true; do
		read -rp "$message" answer
		[[ -z "$answer" ]] && answer="$default"

		answer="${answer##*( )}"
		answer="${answer%%*( )}"
		answer="${answer,,}"

		case "$answer" in
		y|yes) return 0 ;;
		n|no) return 1 ;;
		q|quit|exit) echo "Exiting..."; exit 0 ;;
		*) echo "Choose Y or N" ;;
		esac
	done
}


function choose_dir(){
	local message="$1" type="$2" create="${3-}" answer
	while true; do
		read -rp "Enter $message: " answer
		[[ -d "$answer" ]] && declare -g "absolute_${type}=$(readlink -f -- "$answer")" && return 0
		if [[ ! -z "$create" ]]; then
			if yesno "This directory doesn't exist... Do you want create it? (Y/n): " Y; then
				mkdir -p -- "$answer"
				declare -g "absolute_${type}=$(readlink -f -- "$answer")"
				echo "Directory create is successful"
				return 0
			fi
		else
			echo "This directory doesn't exist... Input correct path"
			echo ""
		fi
	done
}

function cp_tool(){
  SELECTED_TOOL="cp"
  echo "Selected: Standard (rm+cp)"
  return 0
}

function rsync_tool(){
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is not installed. Choose another tool."
    return 1
  fi
  SELECTED_TOOL="rsync"
  echo "Selected: rsync"
  return 0
}

function rclone_tool(){
  if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone is not installed. Choose another tool."
    return 1
  fi
  SELECTED_TOOL="rclone"
  echo "Selected: rclone"
  return 0
}


function choose_tool(){
	local default="$1" choice
	while true; do
		echo "Choose copy tool:"
		echo "1) Standard (cp + rm)"
		echo "2) rsync"
		echo "3) rclone"
		read -rp "Select: " choice
		[[ -z choice ]] && choice=$default

		choice="${choice##*( )}"
		choice="${choice%%*( )}"

		case "$choice" in
			1)  cp_tool && return 0;;
			2)  rsync_tool && return 0;;
			3)  rclone_tool && return 0;;
			*)  echo "-----------" && echo "Enter number from 1 to 3" && echo "";;
		esac
	done
}

choose_dir "source directory" src
choose_dir "destination directory" dst yes

echo ""

# Additional checks
# Check same path
if [[ "$absolute_src" == "$absolute_dst" ]]; then
	echo "Source and destination are same... Abort operation..." >&2
	echo ""
	exit 1
fi

# Check destination path for /
if [[ "$absolute_dst" == "/"  ]]; then
	echo "Destination path use "/". Abort..." >&2
	echo ""
	exit 1
fi

# Check nesting
if [[ "$absolute_src/" == "$absolute_dst"/* || "$absolute_dst/" == "$absolute_src"/* ]]; then
	echo "Source and destination nesting. Abort." >&2
	echo ""
	exit 1
fi

# Check destination path for sensitive directory
if [[ "$absolute_dst" =~ ^/(etc|home|var|bin|usr|lib|opt|tmp|srv|dev|mnt|media|proc|run|sys)(/)?$ ]]; then
	echo "Destination is a sensitive directory: $absolute_dst"
	yesno "Do you want to continue? (y/N): " N || { echo "Aborted..."; exit 1; }
	yesno "Are you absolutely sure? (y/N): " N || { echo "Aborted..."; exit 1; }
fi

choose_tool 1

# Create backup to /tmp
if [[ -e "$absolute_dst" ]]; then
	backup="/tmp/$(basename -- "$absolute_dst").`date +"%H:%M:%S:%3N"`-bak"
	cp -af -- "$absolute_dst" "$backup"
fi

case "$SELECTED_TOOL" in
  rsync)
    rsync -aH --delete --info=progress2 -- "$absolute_src"/ "$absolute_dst"/
    ;;
  rclone)
    rclone sync --progress --copy-links --local-no-check-updated -- "$absolute_src" "$absolute_dst"
    ;;
  cp|*)
    rm -rf -- "$absolute_dst"/* || true
    cp -af -- "$absolute_src"/. "$absolute_dst"/
    ;;
esac

echo "The task was completed successfully. Previous data backed up to: $backup"
echo ""

#!/bin/bash

# =================================================================
#           High-Availability Universal Backup Script
#
# Description:
# This script intelligently backs up a directory. It uses a lock
# file to prevent concurrent runs, calculates a content hash to
# avoid redundant backups, and preserves original file metadata.
#
# This version is optimized for minimal output, making it ideal
# for cron jobs and automated scripts.
#
# Usage:
# ./backup.sh <source_dir> <dest_dir> <prefix> [retention_days]
#
# =================================================================

# --- SCRIPT CONFIGURATION ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error.
set -u
# Pipes fail on the first command that fails, not the last.
set -o pipefail

# --- GLOBAL VARIABLES ---
# The lock file path is global so the trap can find it.
LOCK_FILE=""
# Globals for sharing info between functions without noisy parameters.
DEST_DIR=""
BACKUP_PREFIX=""

# --- CORE LOGIC FUNCTIONS ---

# Function to handle script cleanup on exit. It's silent.
cleanup() {
    if [ -n "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
    fi
}

# Function to calculate the hash of the source directory.
# This function now ONLY outputs the hash value to stdout, which is critical for correctness.
get_current_hash() {
    local source_dir="$1"
    shift
    local -a tar_exclude_args=("$@")

    # The tar and sha256sum pipeline outputs the hash directly.
    # Any informational text was removed to prevent it from being captured
    # by command substitution, which was the cause of the original bug.
    tar --sort=name -c -f - -C "$source_dir" "${tar_exclude_args[@]}" . | sha256sum | awk '{print $1}'
}

# Function to get the latest hash from the log file. It's silent.
get_latest_hash() {
    local hash_log_file="$1"
    local prefix="$2"

    # Ensure log file exists before trying to read it.
    if [ ! -f "$hash_log_file" ]; then
        echo ""
        return
    fi

    # Grep for relevant lines, get the last one, and extract the hash.
    grep -E "^[a-f0-9]{64} ${prefix}_" "$hash_log_file" 2>/dev/null | tail -n 1 | awk '{print $1}' || true
}

# Function to create the backup archive.
# On success, it outputs the new archive's filename. On failure, it outputs nothing to stdout.
create_archive() {
    local source_dir="$1"
    shift
    local -a tar_exclude_args=("$@")

    local comp_cmd
    local archive_extension
    # Prefer zstd for its speed if available.
    if command -v zstd &> /dev/null; then
        comp_cmd="zstd -T0"
        archive_extension="tar.zst"
    else
        comp_cmd="xz -T0"
        archive_extension="tar.xz"
        # A quiet warning to stderr that a slower method is being used.
        echo "Warning: 'zstd' not found, falling back to slower xz compression." >&2
    fi

    # Added seconds to the timestamp to prevent filename collisions.
    local date_suffix
    date_suffix=$(date +"%Y%m%d%H%M%S")
    local final_archive_name
    final_archive_name="${BACKUP_PREFIX}_${date_suffix}.${archive_extension}"
    local full_dest_path="${DEST_DIR}/${final_archive_name}"

    # The core backup command. Errors are redirected to /dev/null for a cleaner log.
    # The script relies on 'set -e' to catch failures.
    if tar -c -f - -C "$source_dir" "${tar_exclude_args[@]}" . | $comp_cmd > "$full_dest_path"; then
        # On success, print the filename for the caller to capture.
        echo "$final_archive_name"
        return 0
    else
        # On failure, print an error to stderr and ensure no partial file is left.
        echo "Error: Backup archive creation failed." >&2
        rm -f "$full_dest_path"
        return 1
    fi
}

# Function to rotate old backups. It's silent.
rotate_backups() {
    local dest_dir="$1"
    local prefix="$2"
    local retention_days="$3"

    # Only run if retention_days is a positive integer.
    if [[ "$retention_days" =~ ^[1-9][0-9]*$ ]]; then
        # Find and delete old backup files quietly.
        find "$dest_dir" -type f -name "${prefix}_*.tar.*" -mtime "+$((retention_days - 1))" -delete
    fi
}

# --- MAIN FUNCTION ---
main() {
    if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
        echo "Error: Invalid number of arguments." >&2
        echo "Usage: $0 <source_directory> <destination_directory> <backup_prefix> [retention_days (optional)]" >&2
        exit 1
    fi
	echo $(date +"%Y-%m-%d %H:%M:%S") Backup start.
    # readlink -f resolves absolute paths, -m creates dest path if needed.
    local source_dir
    source_dir=$(readlink -f "$1")
    DEST_DIR=$(readlink -m "$2") # Set global
    BACKUP_PREFIX="$3"           # Set global
    local retention_days="${4:-0}" # Default to 0 (no rotation) if not set

    # Set the trap to call the cleanup function on script exit.
    trap cleanup EXIT

    # --- Lock File Handling ---
    LOCK_FILE="${DEST_DIR}/${BACKUP_PREFIX}.lock"
    if [ -e "$LOCK_FILE" ]; then
        # Check if the process ID from the lock file is still running.
        local old_pid
        old_pid=$(cat "$LOCK_FILE")
        if ps -p "$old_pid" > /dev/null; then
            echo "Error: Backup for ${BACKUP_PREFIX} is already running (PID: $old_pid). Exiting." >&2
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"

    # --- Pre-flight Checks ---
    if [ ! -d "$source_dir" ]; then echo "Error: Source directory '$source_dir' not found." >&2; exit 1; fi
    if [ ! -w "$DEST_DIR" ]; then echo "Error: Destination directory '$DEST_DIR' is not writable." >&2; exit 1; fi

    # --- Backup Logic ---
    local -a tar_exclude_args=()
    local ignore_file="${source_dir}/.backupignore"
    if [ -f "$ignore_file" ]; then
        tar_exclude_args+=(--exclude-from="$ignore_file")
    fi

    local current_hash
    current_hash=$(get_current_hash "$source_dir" "${tar_exclude_args[@]}")

    local hash_log_file="${DEST_DIR}/hash.log"
    local latest_hash
    latest_hash=$(get_latest_hash "$hash_log_file" "$BACKUP_PREFIX")

    if [ -n "$latest_hash" ] && [ "$current_hash" == "$latest_hash" ]; then
        echo "Backup for ${BACKUP_PREFIX}: SKIPPED (no changes)"
    else
        echo "Backup for ${BACKUP_PREFIX}: IN PROGRESS..."

        local final_archive_name
        final_archive_name=$(create_archive "$source_dir" "${tar_exclude_args[@]}")

        if [ -n "$final_archive_name" ]; then
            # Record the new hash and report success.
            echo "${current_hash} ${final_archive_name}" >> "$hash_log_file"
            echo "Backup for ${BACKUP_PREFIX}: SUCCESS -> ${DEST_DIR}/${final_archive_name}"
        else
            # The create_archive function failed and printed its own error.
            echo "Backup for ${BACKUP_PREFIX}: FAILED" >&2
            exit 1
        fi
    fi

    # Silently apply the retention policy.
    rotate_backups "$DEST_DIR" "$BACKUP_PREFIX" "$retention_days"
    echo $(date +"%Y-%m-%d %H:%M:%S") Backup end.
}

# --- SCRIPT ENTRY POINT ---
# Pass all script arguments to the main function.
main "$@"

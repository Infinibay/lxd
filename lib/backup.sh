#!/usr/bin/env bash

# backup.sh - Infinibay Backup Management Library
#
# This library provides functions for creating, listing, and validating backups
# of the Infinibay system, including PostgreSQL database dumps and git state
# tracking for all repositories (lxd, backend, frontend, libvirt-node).
#
# Main Functions:
#   create_backup [label]  - Create a new timestamped backup
#   list_backups           - List all available backups with metadata
#   validate_backup <path> - Validate backup integrity
#
# Backup Structure:
#   /data/backups/<timestamp>/
#     ├── infinibay_backup.sql     (PostgreSQL dump)
#     ├── backend_commit.txt        (Backend repo commit hash)
#     ├── frontend_commit.txt       (Frontend repo commit hash)
#     ├── lxd_commit.txt           (LXD repo commit hash)
#     ├── libvirt-node_commit.txt  (Libvirt-node repo commit hash)
#     ├── *_status.txt             (Optional: uncommitted changes warning)
#     └── metadata.json            (Backup metadata)
#
# Usage:
#   source lib/backup.sh
#   create_backup "manual"
#   list_backups
#   validate_backup "/data/backups/20250124_153000"

# Color definitions for consistent output formatting
# Only define if not already set (to avoid conflicts when sourced from scripts that define them)
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && readonly CYAN='\033[0;36m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

# Global configuration variables (defaults, may be overridden by backup.conf)
TIMESTAMP_FORMAT="%Y%m%d_%H%M%S"

# load_backup_config - Load backup configuration from backup.conf
#
# Priority order (highest to lowest):
#   1. Environment variables (set before sourcing this library)
#   2. backup.conf settings
#   3. Built-in defaults
#
# Sets the following global variables:
#   BACKUP_ENABLED - Whether backup operations are enabled
#   BACKUP_SCHEDULE - Cron schedule for scheduled backups
#   BACKUP_RETENTION_DAYS - Days to keep scheduled backups
#   BACKUP_RETENTION_COUNT - Max scheduled backups to keep
#   BACKUP_UPDATE_RETENTION_DAYS - Days to keep update/upgrade backups
#   BACKUP_LOCATION - Base directory for backups (inside postgres container)
#   BACKUP_BASE_DIR - Alias for BACKUP_LOCATION (for backward compatibility)
load_backup_config() {
    # Save any environment variables that were set before this function runs
    local env_BACKUP_ENABLED="${BACKUP_ENABLED:-}"
    local env_BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-}"
    local env_BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"
    local env_BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-}"
    local env_BACKUP_UPDATE_RETENTION_DAYS="${BACKUP_UPDATE_RETENTION_DAYS:-}"
    local env_BACKUP_LOCATION="${BACKUP_LOCATION:-}"

    # Clear variables so config file can set them fresh
    unset BACKUP_ENABLED BACKUP_SCHEDULE BACKUP_RETENTION_DAYS
    unset BACKUP_RETENTION_COUNT BACKUP_UPDATE_RETENTION_DAYS BACKUP_LOCATION

    # Try to find and source backup.conf
    local config_file=""
    local script_dir

    # Determine script directory
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # backup.conf is in parent directory (lxd/)
        config_file="$script_dir/../backup.conf"
    fi

    # Source config file if it exists (sets variables from config)
    if [[ -n "$config_file" ]] && [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    fi

    # Apply defaults for any variables not set by config file
    BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
    BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 2 * * *}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-10}"
    BACKUP_UPDATE_RETENTION_DAYS="${BACKUP_UPDATE_RETENTION_DAYS:-30}"
    BACKUP_LOCATION="${BACKUP_LOCATION:-/data/backups}"

    # Environment variables override everything (highest priority)
    [[ -n "$env_BACKUP_ENABLED" ]] && BACKUP_ENABLED="$env_BACKUP_ENABLED"
    [[ -n "$env_BACKUP_SCHEDULE" ]] && BACKUP_SCHEDULE="$env_BACKUP_SCHEDULE"
    [[ -n "$env_BACKUP_RETENTION_DAYS" ]] && BACKUP_RETENTION_DAYS="$env_BACKUP_RETENTION_DAYS"
    [[ -n "$env_BACKUP_RETENTION_COUNT" ]] && BACKUP_RETENTION_COUNT="$env_BACKUP_RETENTION_COUNT"
    [[ -n "$env_BACKUP_UPDATE_RETENTION_DAYS" ]] && BACKUP_UPDATE_RETENTION_DAYS="$env_BACKUP_UPDATE_RETENTION_DAYS"
    [[ -n "$env_BACKUP_LOCATION" ]] && BACKUP_LOCATION="$env_BACKUP_LOCATION"

    # Set BACKUP_BASE_DIR for backward compatibility
    BACKUP_BASE_DIR="$BACKUP_LOCATION"

    return 0
}

# Load configuration when library is sourced
load_backup_config

# get_backup_type - Determine backup type from directory name
#
# Arguments:
#   $1 - Backup directory name (e.g., "manual_before-test_20250130_120000")
#
# Returns:
#   Backup type string: "manual", "update", "upgrade", "scheduled", or "unknown"
get_backup_type() {
    local backup_name="$1"

    case "$backup_name" in
        manual_*)
            echo "manual"
            ;;
        update_*)
            echo "update"
            ;;
        upgrade_*)
            echo "upgrade"
            ;;
        scheduled_*)
            echo "scheduled"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# get_backup_retention_info - Get retention info for a backup type
#
# Arguments:
#   $1 - Backup type (manual, update, upgrade, scheduled, unknown)
#
# Returns:
#   Human-readable retention info string
get_backup_retention_info() {
    local backup_type="$1"

    case "$backup_type" in
        manual)
            echo "never deleted"
            ;;
        update|upgrade)
            echo "kept ${BACKUP_UPDATE_RETENTION_DAYS} days"
            ;;
        scheduled|unknown)
            echo "kept ${BACKUP_RETENTION_DAYS}d OR last ${BACKUP_RETENTION_COUNT}"
            ;;
        *)
            echo "kept ${BACKUP_RETENTION_DAYS}d OR last ${BACKUP_RETENTION_COUNT}"
            ;;
    esac
}

# ensure_backup_directory - Ensure backup directory exists in postgres container
#
# Creates the backup base directory if it doesn't exist and verifies write permissions.
# This function is idempotent and safe to call multiple times.
#
# Returns:
#   0 - Directory exists and is writable
#   1 - Failed to create directory or insufficient permissions
ensure_backup_directory() {
    echo -e "${BLUE}[ensure_backup_directory]${NC} Checking backup directory..."

    # Check if postgres container is running
    if ! check_container_running "infinibay-postgres"; then
        echo -e "${RED}[ensure_backup_directory]${NC} Error: infinibay-postgres container is not running"
        return 1
    fi

    # Create backup directory if it doesn't exist
    if ! lxc exec infinibay-postgres -- mkdir -p "$BACKUP_BASE_DIR" 2>/dev/null; then
        echo -e "${RED}[ensure_backup_directory]${NC} Error: Failed to create backup directory"
        echo -e "${YELLOW}[ensure_backup_directory]${NC} Hint: Check container permissions and disk space"
        return 1
    fi

    # Verify directory is writable
    if ! lxc exec infinibay-postgres -- test -w "$BACKUP_BASE_DIR"; then
        echo -e "${RED}[ensure_backup_directory]${NC} Error: Backup directory is not writable"
        return 1
    fi

    echo -e "${GREEN}[ensure_backup_directory]${NC} Backup directory ready: $BACKUP_BASE_DIR"
    return 0
}

# generate_timestamp - Generate current timestamp in backup format
#
# Returns:
#   Timestamp string in format YYYYMMDD_HHMMSS
generate_timestamp() {
    date +"$TIMESTAMP_FORMAT"
}

# get_git_commit - Get git commit hash from repository
#
# Arguments:
#   $1 - Container name (use "host" for host filesystem)
#   $2 - Repository path
#
# Returns:
#   0 - Success, commit hash printed to stdout
#   1 - Error (repo doesn't exist, container stopped, etc.)
get_git_commit() {
    local container="$1"
    local repo_path="$2"
    local commit_hash

    if [[ "$container" == "host" ]]; then
        # Execute git command on host
        commit_hash=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null)
    else
        # Check if container is running
        if ! check_container_running "$container"; then
            echo -e "${YELLOW}[get_git_commit]${NC} Warning: Container $container is not running" >&2
            return 1
        fi

        # Execute git command in container
        commit_hash=$(lxc exec "$container" -- git -C "$repo_path" rev-parse HEAD 2>/dev/null)
    fi

    if [[ -z "$commit_hash" ]]; then
        echo -e "${YELLOW}[get_git_commit]${NC} Warning: Failed to get commit hash from $repo_path in $container" >&2
        return 1
    fi

    echo "$commit_hash"
    return 0
}

# get_git_status - Check if repository has uncommitted changes
#
# Arguments:
#   $1 - Container name (use "host" for host filesystem)
#   $2 - Repository path
#
# Returns:
#   "clean" - No uncommitted changes
#   "dirty" - Has uncommitted changes
#   "unknown" - Error checking status
get_git_status() {
    local container="$1"
    local repo_path="$2"
    local status_output

    if [[ "$container" == "host" ]]; then
        status_output=$(git -C "$repo_path" status --porcelain 2>/dev/null)
    else
        if ! check_container_running "$container"; then
            echo "unknown"
            return 1
        fi
        status_output=$(lxc exec "$container" -- git -C "$repo_path" status --porcelain 2>/dev/null)
    fi

    if [[ $? -ne 0 ]]; then
        echo "unknown"
        return 1
    fi

    if [[ -z "$status_output" ]]; then
        echo "clean"
    else
        echo "dirty"
    fi

    return 0
}

# check_container_running - Verify if container is running
#
# Arguments:
#   $1 - Container name
#
# Returns:
#   0 - Container is running
#   1 - Container is not running or doesn't exist
check_container_running() {
    local container="$1"
    local status

    status=$(lxc list "$container" --format=csv -c s 2>/dev/null)

    if [[ "$status" == "RUNNING" ]]; then
        return 0
    else
        return 1
    fi
}

# cleanup_old_backups - Apply retention policy to remove old backups
#
# Implements the full retention policy:
#   - Manual backups (manual_*): Never deleted
#   - Update/Upgrade backups (update_*, upgrade_*): Deleted after BACKUP_UPDATE_RETENTION_DAYS
#   - Scheduled backups (scheduled_*) and unknown/unlabeled backups: Use union retention semantics
#     A backup is KEPT if it is within BACKUP_RETENTION_DAYS OR is one of the last BACKUP_RETENTION_COUNT
#     This ensures you always have at least BACKUP_RETENTION_COUNT backups even if they're older
#
# Returns:
#   0 - Cleanup completed (even if nothing was deleted)
#   1 - Error (container not running, etc.)
cleanup_old_backups() {
    echo -e "${BLUE}[cleanup_old_backups]${NC} Starting backup cleanup..."

    # Check if postgres container is running
    if ! check_container_running "infinibay-postgres"; then
        echo -e "${RED}[cleanup_old_backups]${NC} Error: infinibay-postgres container is not running"
        return 1
    fi

    # Check if backup directory exists
    if ! lxc exec infinibay-postgres -- test -d "$BACKUP_BASE_DIR"; then
        echo -e "${YELLOW}[cleanup_old_backups]${NC} Backup directory doesn't exist, nothing to clean"
        return 0
    fi

    # Get list of all backup directories (excluding 'current' symlink)
    local all_backups
    all_backups=$(lxc exec infinibay-postgres -- ls -1 "$BACKUP_BASE_DIR" 2>/dev/null | grep -v "^current$")

    if [[ -z "$all_backups" ]]; then
        echo -e "${YELLOW}[cleanup_old_backups]${NC} No backups found"
        return 0
    fi

    local deleted_count=0
    local manual_count=0
    local update_count=0
    local scheduled_count=0

    # First pass: Delete old update/upgrade backups based on age
    echo -e "${BLUE}[cleanup_old_backups]${NC} Checking update/upgrade backups (retention: ${BACKUP_UPDATE_RETENTION_DAYS} days)..."
    while IFS= read -r backup_name; do
        [[ -z "$backup_name" ]] && continue

        local backup_type
        backup_type=$(get_backup_type "$backup_name")

        if [[ "$backup_type" == "update" ]] || [[ "$backup_type" == "upgrade" ]]; then
            local backup_path="$BACKUP_BASE_DIR/$backup_name"

            # Check if backup is older than retention period using find
            local is_old
            is_old=$(lxc exec infinibay-postgres -- find "$backup_path" -maxdepth 0 -mtime +${BACKUP_UPDATE_RETENTION_DAYS} 2>/dev/null)

            if [[ -n "$is_old" ]]; then
                echo -e "${YELLOW}[cleanup_old_backups]${NC} Removing old $backup_type backup: $backup_name"
                lxc exec infinibay-postgres -- rm -rf "$backup_path"
                deleted_count=$((deleted_count + 1))
            else
                update_count=$((update_count + 1))
            fi
        elif [[ "$backup_type" == "manual" ]]; then
            manual_count=$((manual_count + 1))
        fi
    done <<< "$all_backups"

    # Second pass: Apply union retention policy for scheduled and unknown backups
    # Keep backups that are: within BACKUP_RETENTION_DAYS OR one of the last BACKUP_RETENTION_COUNT
    echo -e "${BLUE}[cleanup_old_backups]${NC} Checking scheduled/unknown backups (retention: ${BACKUP_RETENTION_DAYS} days OR last ${BACKUP_RETENTION_COUNT})..."

    # Refresh backup list after first pass
    all_backups=$(lxc exec infinibay-postgres -- ls -1 "$BACKUP_BASE_DIR" 2>/dev/null | grep -v "^current$")

    # Build list of scheduled and unknown backups sorted by modification time (newest first)
    local scheduled_and_unknown_backups=""
    while IFS= read -r backup_name; do
        [[ -z "$backup_name" ]] && continue
        local backup_type
        backup_type=$(get_backup_type "$backup_name")
        if [[ "$backup_type" == "scheduled" ]] || [[ "$backup_type" == "unknown" ]]; then
            scheduled_and_unknown_backups+="$backup_name"$'\n'
        fi
    done <<< "$all_backups"

    # If no scheduled/unknown backups, we're done
    if [[ -z "$scheduled_and_unknown_backups" ]]; then
        echo -e "${GREEN}[cleanup_old_backups]${NC} No scheduled/unknown backups to process"
    else
        # Sort backups by modification time (newest first) inside the container
        local sorted_backups
        sorted_backups=$(lxc exec infinibay-postgres -- bash -c "
            for name in $scheduled_and_unknown_backups; do
                [[ -d \"$BACKUP_BASE_DIR/\$name\" ]] && echo \"\$name\"
            done | while read name; do
                stat -c '%Y %n' \"$BACKUP_BASE_DIR/\$name\" 2>/dev/null
            done | sort -rn | cut -d' ' -f2 | xargs -r -n1 basename
        " 2>/dev/null)

        # Build sets for union retention policy
        # Set 1: Backups within BACKUP_RETENTION_DAYS
        # Set 2: Last BACKUP_RETENTION_COUNT backups
        local backups_to_keep=""
        local count=0

        while IFS= read -r backup_name; do
            [[ -z "$backup_name" ]] && continue
            count=$((count + 1))

            local backup_path="$BACKUP_BASE_DIR/$backup_name"
            local keep_by_age=false
            local keep_by_count=false

            # Check if within retention days
            local is_old
            is_old=$(lxc exec infinibay-postgres -- find "$backup_path" -maxdepth 0 -mtime +${BACKUP_RETENTION_DAYS} 2>/dev/null)
            if [[ -z "$is_old" ]]; then
                keep_by_age=true
            fi

            # Check if within count limit
            if [[ $count -le $BACKUP_RETENTION_COUNT ]]; then
                keep_by_count=true
            fi

            # Union semantics: keep if EITHER condition is met
            if [[ "$keep_by_age" == "true" ]] || [[ "$keep_by_count" == "true" ]]; then
                backups_to_keep+="$backup_name"$'\n'
                scheduled_count=$((scheduled_count + 1))
            else
                echo -e "${YELLOW}[cleanup_old_backups]${NC} Removing old scheduled/unknown backup: $backup_name"
                lxc exec infinibay-postgres -- rm -rf "$backup_path"
                deleted_count=$((deleted_count + 1))
            fi
        done <<< "$sorted_backups"
    fi

    # Summary
    echo -e "${GREEN}[cleanup_old_backups]${NC} Cleanup complete:"
    echo -e "${GREEN}[cleanup_old_backups]${NC}   Deleted: $deleted_count backup(s)"
    echo -e "${GREEN}[cleanup_old_backups]${NC}   Remaining: manual=$manual_count, update/upgrade=$update_count, scheduled/unknown=$scheduled_count"

    return 0
}

# create_backup - Create a new timestamped backup
#
# Creates a complete backup including PostgreSQL database dump, git commit hashes
# from all repositories, and metadata. Applies retention policy to keep only the
# most recent backups.
#
# IMPORTANT: This function requires infinibay-postgres, infinibay-backend, and
# infinibay-frontend containers to exist and be accessible. The backup will fail
# if these containers are missing, as their git state is essential for rollback
# operations. Backups with "unknown" commit hashes for backend or frontend are
# NOT supported for rollback.
#
# The libvirt-node repository is optional for rollback. If the libvirt-node
# container is unavailable or the commit hash is "unknown", the backup can still
# be used for rollback, but the libvirt-node rollback step will be skipped with
# a warning.
#
# Arguments:
#   $1 - Optional label (e.g., "update", "upgrade", "manual")
#
# Returns:
#   0 - Backup created successfully with all repository states captured
#   1 - Backup failed due to missing containers or other errors
create_backup() {
    local label="$1"
    local timestamp
    local backup_dir_name
    local backup_path
    local cleanup_on_error=0

    # Check if backup functionality is enabled globally
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        echo -e "${RED}[create_backup]${NC} Error: Backup functionality is disabled"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Set BACKUP_ENABLED=true in backup.conf or environment"
        return 1
    fi

    echo -e "${BLUE}[create_backup]${NC} Starting backup process..."

    # Validate prerequisites
    echo -e "${BLUE}[create_backup]${NC} Validating prerequisites..."

    if ! check_container_running "infinibay-postgres"; then
        echo -e "${RED}[create_backup]${NC} Error: infinibay-postgres container is not running"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Start the container with 'lxc start infinibay-postgres'"
        return 1
    fi

    if ! lxc list infinibay-backend --format=csv -c n 2>/dev/null | grep -q "infinibay-backend"; then
        echo -e "${RED}[create_backup]${NC} Error: infinibay-backend container not found"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Backend container is required for capturing git state"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Backups without backend git state cannot be used for rollback"
        return 1
    fi

    if ! lxc list infinibay-frontend --format=csv -c n 2>/dev/null | grep -q "infinibay-frontend"; then
        echo -e "${RED}[create_backup]${NC} Error: infinibay-frontend container not found"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Frontend container is required for capturing git state"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Backups without frontend git state cannot be used for rollback"
        return 1
    fi

    # Ensure backup directory exists
    if ! ensure_backup_directory; then
        return 1
    fi

    # Generate timestamp and backup directory name
    timestamp=$(generate_timestamp)
    if [[ -n "$label" ]]; then
        backup_dir_name="${label}_${timestamp}"
    else
        backup_dir_name="$timestamp"
    fi
    backup_path="$BACKUP_BASE_DIR/$backup_dir_name"

    echo -e "${BLUE}[create_backup]${NC} Creating backup: $backup_dir_name"

    # Create backup directory
    if ! lxc exec infinibay-postgres -- mkdir -p "$backup_path"; then
        echo -e "${RED}[create_backup]${NC} Error: Failed to create backup directory"
        return 1
    fi
    cleanup_on_error=1

    # PostgreSQL Backup
    echo -e "${BLUE}[create_backup]${NC} Dumping PostgreSQL database..."
    local pg_exit_code=0
    lxc exec infinibay-postgres -- su - postgres -c "pg_dump infinibay > $backup_path/infinibay_backup.sql" 2>/dev/null || pg_exit_code=$?

    if [[ $pg_exit_code -ne 0 ]]; then
        echo -e "${RED}[create_backup]${NC} Error: PostgreSQL dump failed (exit code: $pg_exit_code)"
        echo -e "${YELLOW}[create_backup]${NC} Hint: Check PostgreSQL logs and verify database is accessible"
        if [[ $cleanup_on_error -eq 1 ]]; then
            lxc exec infinibay-postgres -- rm -rf "$backup_path" 2>/dev/null
        fi
        return 1
    fi

    # Verify SQL dump was created and has non-zero size
    local sql_size
    sql_size=$(lxc exec infinibay-postgres -- stat -c%s "$backup_path/infinibay_backup.sql" 2>/dev/null)
    if [[ -z "$sql_size" ]] || [[ "$sql_size" -eq 0 ]]; then
        echo -e "${RED}[create_backup]${NC} Error: PostgreSQL dump file is empty or doesn't exist"
        if [[ $cleanup_on_error -eq 1 ]]; then
            lxc exec infinibay-postgres -- rm -rf "$backup_path" 2>/dev/null
        fi
        return 1
    fi

    echo -e "${GREEN}[create_backup]${NC} Database dump completed ($(numfmt --to=iec-i --suffix=B $sql_size 2>/dev/null || echo "$sql_size bytes"))"

    # Git State Capture
    echo -e "${BLUE}[create_backup]${NC} Capturing git state from repositories..."

    # Define repositories with their container locations and paths
    declare -A repos=(
        ["lxd"]="host|/home/andres/infinibay/lxd"
        ["backend"]="infinibay-backend|/opt/infinibay/backend"
        ["frontend"]="infinibay-frontend|/opt/infinibay/frontend"
        ["libvirt-node"]="infinibay-backend|/opt/infinibay/libvirt-node"
    )

    local repos_json="["
    local first_repo=1

    for repo_name in "${!repos[@]}"; do
        IFS='|' read -r repo_container repo_path <<< "${repos[$repo_name]}"

        echo -e "${BLUE}[create_backup]${NC} Processing $repo_name repository..."

        # Get commit hash
        local commit_hash
        commit_hash=$(get_git_commit "$repo_container" "$repo_path")
        local commit_status=$?

        if [[ $commit_status -ne 0 ]] || [[ -z "$commit_hash" ]]; then
            echo -e "${YELLOW}[create_backup]${NC} Warning: Could not get commit hash for $repo_name"
            commit_hash="unknown"
        fi

        # Get git status
        local git_status
        git_status=$(get_git_status "$repo_container" "$repo_path")

        # Write commit hash to file
        printf '%s\n' "$commit_hash" | lxc exec infinibay-postgres -- tee "$backup_path/${repo_name}_commit.txt" > /dev/null

        # If repo has uncommitted changes, write warning
        if [[ "$git_status" == "dirty" ]]; then
            echo -e "${YELLOW}[create_backup]${NC} Warning: $repo_name has uncommitted changes"
            printf '%s\n' 'WARNING: Repository had uncommitted changes at backup time' | lxc exec infinibay-postgres -- tee "$backup_path/${repo_name}_status.txt" > /dev/null
        fi

        # Build JSON entry for metadata
        if [[ $first_repo -eq 0 ]]; then
            repos_json+=","
        fi
        first_repo=0

        repos_json+=$(cat <<EOF
{
      "name": "$repo_name",
      "commit": "$commit_hash",
      "status": "$git_status",
      "container": "$repo_container",
      "path": "$repo_path"
    }
EOF
        )

        echo -e "${GREEN}[create_backup]${NC} $repo_name: ${commit_hash:0:7} ($git_status)"
    done

    repos_json+="]"

    # Metadata Generation
    echo -e "${BLUE}[create_backup]${NC} Generating metadata..."

    local iso_timestamp
    iso_timestamp=$(date -Iseconds)

    local db_size_human
    db_size_human=$(lxc exec infinibay-postgres -- du -h "$backup_path/infinibay_backup.sql" 2>/dev/null | cut -f1)

    local metadata_json
    metadata_json=$(cat <<EOF
{
  "timestamp": "$iso_timestamp",
  "backup_name": "$backup_dir_name",
  "label": "${label:-null}",
  "database_name": "infinibay",
  "database_size": "$db_size_human",
  "backup_directory": "$backup_path",
  "repositories": $repos_json
}
EOF
    )

    # Write metadata.json
    lxc exec infinibay-postgres -- bash -c "cat > $backup_path/metadata.json <<'METADATA_EOF'
$metadata_json
METADATA_EOF"

    if [[ $? -ne 0 ]]; then
        echo -e "${YELLOW}[create_backup]${NC} Warning: Failed to write metadata.json"
    else
        echo -e "${GREEN}[create_backup]${NC} Metadata generated successfully"
    fi

    # Update Symlink
    echo -e "${BLUE}[create_backup]${NC} Updating current backup symlink..."
    lxc exec infinibay-postgres -- ln -sfn "$backup_path" "$BACKUP_BASE_DIR/current"

    # Apply Retention Policy
    echo -e "${BLUE}[create_backup]${NC} Applying retention policy..."
    cleanup_old_backups

    # Success message
    echo -e "${GREEN}[create_backup]${NC} ========================================="
    echo -e "${GREEN}[create_backup]${NC} Backup created successfully!"
    echo -e "${GREEN}[create_backup]${NC} ========================================="
    echo -e "${GREEN}[create_backup]${NC} Backup name: $backup_dir_name"
    echo -e "${GREEN}[create_backup]${NC} Location: $backup_path"
    echo -e "${GREEN}[create_backup]${NC} Database size: $db_size_human"
    echo -e "${GREEN}[create_backup]${NC} Timestamp: $iso_timestamp"
    if [[ -n "$label" ]]; then
        echo -e "${GREEN}[create_backup]${NC} Label: $label"
    fi
    echo -e "${GREEN}[create_backup]${NC} ========================================="

    return 0
}

# list_backups - List all available backups with metadata
#
# Displays formatted list of all backups including timestamp, label, size,
# and git commit information. Uses color coding to indicate backup status.
#
# Returns:
#   0 - Success
#   1 - Error
list_backups() {
    echo -e "${BLUE}[list_backups]${NC} Listing available backups..."

    # Check if postgres container is running
    if ! check_container_running "infinibay-postgres"; then
        echo -e "${RED}[list_backups]${NC} Error: infinibay-postgres container is not running"
        return 1
    fi

    # Check if backup directory exists
    if ! lxc exec infinibay-postgres -- test -d "$BACKUP_BASE_DIR"; then
        echo -e "${YELLOW}[list_backups]${NC} No backups found (backup directory doesn't exist)"
        return 0
    fi

    # Get list of backup directories
    local backups
    backups=$(lxc exec infinibay-postgres -- ls -1 "$BACKUP_BASE_DIR" 2>/dev/null | grep -v "^current$" | sort -r)

    if [[ -z "$backups" ]]; then
        echo -e "${YELLOW}[list_backups]${NC} No backups found"
        return 0
    fi

    # Show current symlink target
    local current_target
    current_target=$(lxc exec infinibay-postgres -- readlink "$BACKUP_BASE_DIR/current" 2>/dev/null | xargs basename 2>/dev/null)
    if [[ -n "$current_target" ]]; then
        echo -e "${BLUE}[list_backups]${NC} Current backup: ${GREEN}$current_target${NC}"
        echo ""
    fi

    # Display header
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}Available Backups${NC}"
    echo -e "${BLUE}=========================================${NC}"

    local backup_count=0
    local total_size=0

    while IFS= read -r backup_name; do
        if [[ -z "$backup_name" ]]; then
            continue
        fi

        backup_count=$((backup_count + 1))
        local backup_path="$BACKUP_BASE_DIR/$backup_name"

        # Determine backup type and color
        local backup_type
        backup_type=$(get_backup_type "$backup_name")
        local retention_info
        retention_info=$(get_backup_retention_info "$backup_type")

        # Set color based on backup type
        local type_color
        case "$backup_type" in
            manual)
                type_color="$BLUE"
                ;;
            update|upgrade)
                type_color="$GREEN"
                ;;
            scheduled)
                type_color="$CYAN"
                ;;
            *)
                type_color="$YELLOW"
                ;;
        esac

        # Check if backup is current
        local current_marker=""
        if [[ "$backup_name" == "$current_target" ]]; then
            current_marker=" ${GREEN}[CURRENT]${NC}"
        fi

        # Try to read metadata.json
        local metadata
        metadata=$(lxc exec infinibay-postgres -- cat "$backup_path/metadata.json" 2>/dev/null)

        if [[ -n "$metadata" ]]; then
            # Parse metadata (basic parsing without jq dependency)
            local timestamp label db_size
            timestamp=$(echo "$metadata" | grep '"timestamp"' | cut -d'"' -f4)
            label=$(echo "$metadata" | grep '"label"' | cut -d'"' -f4)
            db_size=$(echo "$metadata" | grep '"database_size"' | cut -d'"' -f4)

            # Check for uncommitted changes
            local has_dirty=0
            if lxc exec infinibay-postgres -- grep -q "dirty" "$backup_path/metadata.json" 2>/dev/null; then
                has_dirty=1
            fi

            # Determine color based on status
            local color="$GREEN"
            local status_text=""
            if [[ $has_dirty -eq 1 ]]; then
                color="$YELLOW"
                status_text=" ${YELLOW}[UNCOMMITTED CHANGES]${NC}"
            fi

            # Check if backup is complete
            if ! lxc exec infinibay-postgres -- test -f "$backup_path/infinibay_backup.sql"; then
                color="$RED"
                status_text=" ${RED}[INCOMPLETE]${NC}"
            fi

            # Display backup information
            echo -e "${color}$backup_name${NC}$current_marker$status_text"
            echo -e "  Type: ${type_color}$backup_type${NC} ($retention_info)"
            echo -e "  Timestamp: $timestamp"
            if [[ -n "$label" ]] && [[ "$label" != "null" ]]; then
                echo -e "  Label: $label"
            fi
            echo -e "  Database: $db_size"

            # Show git commits (abbreviated)
            echo -n "  Commits: "
            local commits=""
            for repo in lxd backend frontend libvirt-node; do
                local commit
                commit=$(lxc exec infinibay-postgres -- cat "$backup_path/${repo}_commit.txt" 2>/dev/null | tr -d '\n')
                if [[ -n "$commit" ]] && [[ "$commit" != "unknown" ]]; then
                    commits+="$repo:${commit:0:7} "
                fi
            done
            echo -e "$commits"

        else
            # No metadata, show basic info
            echo -e "${RED}$backup_name${NC}$current_marker ${RED}[NO METADATA]${NC}"
            echo -e "  Type: ${type_color}$backup_type${NC} ($retention_info)"

            local sql_size
            sql_size=$(lxc exec infinibay-postgres -- du -h "$backup_path/infinibay_backup.sql" 2>/dev/null | cut -f1)
            if [[ -n "$sql_size" ]]; then
                echo -e "  Database: $sql_size"
            fi
        fi

        echo ""
    done <<< "$backups"

    # Display summary
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}Total backups: $backup_count${NC}"

    # Calculate total disk usage
    local total_size_output
    total_size_output=$(lxc exec infinibay-postgres -- du -sh "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1)
    if [[ -n "$total_size_output" ]]; then
        echo -e "${BLUE}Total disk usage: $total_size_output${NC}"
    fi
    echo -e "${BLUE}=========================================${NC}"

    return 0
}

# validate_backup - Validate backup integrity
#
# Performs comprehensive validation of a backup including file existence,
# SQL dump validity, metadata parsing, and git commit hash validation.
#
# Required for rollback:
#   - infinibay_backup.sql (database dump)
#   - backend_commit.txt (must not be "unknown")
#   - frontend_commit.txt (must not be "unknown")
#
# Optional for rollback:
#   - libvirt-node_commit.txt (rollback skipped if missing or "unknown")
#   - lxd_commit.txt (informational only, not used in rollback)
#
# Arguments:
#   $1 - Backup directory path (e.g., "/data/backups/20250124_153000")
#
# Returns:
#   0 - Backup is valid and can be used for rollback
#   1 - Backup validation failed
validate_backup() {
    local backup_path="$1"

    if [[ -z "$backup_path" ]]; then
        echo -e "${RED}[validate_backup]${NC} Error: Backup path is required"
        echo -e "${YELLOW}[validate_backup]${NC} Usage: validate_backup <backup_path>"
        return 1
    fi

    echo -e "${BLUE}[validate_backup]${NC} Validating backup: $backup_path"

    # Check if postgres container is running
    if ! check_container_running "infinibay-postgres"; then
        echo -e "${RED}[validate_backup]${NC} Error: infinibay-postgres container is not running"
        return 1
    fi

    local validation_failed=0

    # Check if backup directory exists
    echo -e "${BLUE}[validate_backup]${NC} Checking backup directory..."
    if ! lxc exec infinibay-postgres -- test -d "$backup_path"; then
        echo -e "${RED}[validate_backup]${NC} ✗ Backup directory does not exist"
        return 1
    fi
    echo -e "${GREEN}[validate_backup]${NC} ✓ Backup directory exists"

    # File Existence Checks
    echo -e "${BLUE}[validate_backup]${NC} Checking required files..."

    # Check SQL dump
    if ! lxc exec infinibay-postgres -- test -f "$backup_path/infinibay_backup.sql"; then
        echo -e "${RED}[validate_backup]${NC} ✗ Missing infinibay_backup.sql"
        validation_failed=1
    else
        # Check if file is non-empty
        local sql_size
        sql_size=$(lxc exec infinibay-postgres -- stat -c%s "$backup_path/infinibay_backup.sql" 2>/dev/null)
        if [[ -z "$sql_size" ]] || [[ "$sql_size" -eq 0 ]]; then
            echo -e "${RED}[validate_backup]${NC} ✗ infinibay_backup.sql is empty"
            validation_failed=1
        else
            echo -e "${GREEN}[validate_backup]${NC} ✓ infinibay_backup.sql exists ($(numfmt --to=iec-i --suffix=B $sql_size 2>/dev/null || echo "$sql_size bytes"))"
        fi
    fi

    # Check metadata.json
    if ! lxc exec infinibay-postgres -- test -f "$backup_path/metadata.json"; then
        echo -e "${YELLOW}[validate_backup]${NC} ⚠ Missing metadata.json"
    else
        echo -e "${GREEN}[validate_backup]${NC} ✓ metadata.json exists"
    fi

    # Check commit files for each repo
    local required_repos=("backend" "frontend")
    local optional_repos=("lxd" "libvirt-node")

    for repo in "${required_repos[@]}"; do
        if ! lxc exec infinibay-postgres -- test -f "$backup_path/${repo}_commit.txt"; then
            echo -e "${RED}[validate_backup]${NC} ✗ Missing ${repo}_commit.txt"
            validation_failed=1
        else
            echo -e "${GREEN}[validate_backup]${NC} ✓ ${repo}_commit.txt exists"
        fi
    done

    for repo in "${optional_repos[@]}"; do
        if ! lxc exec infinibay-postgres -- test -f "$backup_path/${repo}_commit.txt"; then
            echo -e "${YELLOW}[validate_backup]${NC} ⚠ Missing ${repo}_commit.txt (optional)"
        else
            echo -e "${GREEN}[validate_backup]${NC} ✓ ${repo}_commit.txt exists"
        fi
    done

    # SQL Dump Validation
    echo -e "${BLUE}[validate_backup]${NC} Validating SQL dump..."
    local sql_header
    sql_header=$(lxc exec infinibay-postgres -- head -n 5 "$backup_path/infinibay_backup.sql" 2>/dev/null)

    if echo "$sql_header" | grep -q "PostgreSQL database dump"; then
        echo -e "${GREEN}[validate_backup]${NC} ✓ SQL dump has valid PostgreSQL header"
    else
        echo -e "${RED}[validate_backup]${NC} ✗ SQL dump does not appear to be a valid PostgreSQL dump"
        validation_failed=1
    fi

    # Metadata Validation
    if lxc exec infinibay-postgres -- test -f "$backup_path/metadata.json"; then
        echo -e "${BLUE}[validate_backup]${NC} Validating metadata..."

        local metadata
        metadata=$(lxc exec infinibay-postgres -- cat "$backup_path/metadata.json" 2>/dev/null)

        # Check if metadata is valid JSON (basic check)
        if echo "$metadata" | grep -q '"timestamp"' && echo "$metadata" | grep -q '"database_name"'; then
            echo -e "${GREEN}[validate_backup]${NC} ✓ metadata.json has required fields"

            # Check for repositories array
            if echo "$metadata" | grep -q '"repositories"'; then
                echo -e "${GREEN}[validate_backup]${NC} ✓ metadata.json contains repositories information"
            else
                echo -e "${YELLOW}[validate_backup]${NC} ⚠ metadata.json missing repositories array"
            fi
        else
            echo -e "${RED}[validate_backup]${NC} ✗ metadata.json is missing required fields"
            validation_failed=1
        fi
    fi

    # Git Commit Validation
    echo -e "${BLUE}[validate_backup]${NC} Validating git commits..."

    for repo in lxd backend frontend libvirt-node; do
        if lxc exec infinibay-postgres -- test -f "$backup_path/${repo}_commit.txt"; then
            local commit
            commit=$(lxc exec infinibay-postgres -- cat "$backup_path/${repo}_commit.txt" 2>/dev/null | tr -d '\n')

            if [[ "$commit" == "unknown" ]]; then
                echo -e "${YELLOW}[validate_backup]${NC} ⚠ $repo commit is unknown"
            elif [[ ${#commit} -eq 40 ]] || [[ ${#commit} -eq 7 ]]; then
                # Valid SHA-1 hash (40 chars) or abbreviated (7 chars)
                if [[ "$commit" =~ ^[0-9a-f]+$ ]]; then
                    echo -e "${GREEN}[validate_backup]${NC} ✓ $repo commit is valid (${commit:0:7})"
                else
                    echo -e "${RED}[validate_backup]${NC} ✗ $repo commit has invalid format"
                    validation_failed=1
                fi
            else
                echo -e "${RED}[validate_backup]${NC} ✗ $repo commit has invalid length (${#commit})"
                validation_failed=1
            fi

            # Check for uncommitted changes warning
            if lxc exec infinibay-postgres -- test -f "$backup_path/${repo}_status.txt"; then
                echo -e "${YELLOW}[validate_backup]${NC} ⚠ $repo had uncommitted changes at backup time"
            fi
        fi
    done

    # Final validation result
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    if [[ $validation_failed -eq 0 ]]; then
        echo -e "${GREEN}[validate_backup]${NC} ✓ Backup validation PASSED"
        echo -e "${GREEN}[validate_backup]${NC} Backup is valid and can be restored"
        echo -e "${BLUE}=========================================${NC}"
        return 0
    else
        echo -e "${RED}[validate_backup]${NC} ✗ Backup validation FAILED"
        echo -e "${RED}[validate_backup]${NC} Backup may be corrupted or incomplete"
        echo -e "${YELLOW}[validate_backup]${NC} Hint: Review errors above and consider creating a new backup"
        echo -e "${BLUE}=========================================${NC}"
        return 1
    fi
}

#!/usr/bin/env bash

# progress.sh - Infinibay Progress Indicator Library
#
# This library provides functions for displaying progress indicators during
# update and upgrade operations, including phase tracking, step progress,
# elapsed time, and progress bars.
#
# Main Functions:
#   start_phase <name> <total_steps>  - Initialize phase tracking
#   update_step <n> <name> <status>   - Display current step with status
#   show_progress_bar <cur> <tot> <label>  - Display ASCII progress bar
#   estimate_time <operation>         - Return estimated duration
#   display_elapsed_time <start>      - Format elapsed time
#   phase_summary <name> <start> <status>  - Display phase completion summary
#
# Usage:
#   source lib/progress.sh
#   start_phase "Backup" 3
#   update_step 1 "Creating database dump" "in-progress"
#   update_step 1 "Creating database dump" "complete"
#   phase_summary "Backup" $PHASE_START_TIME "success"

set -e

# Color definitions for consistent output formatting
# Only define if not already set (to avoid conflicts when sourced from scripts that define them)
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${CYAN:-}" ]] && readonly CYAN='\033[0;36m'
[[ -z "${BOLD:-}" ]] && readonly BOLD='\033[1m'
[[ -z "${DIM:-}" ]] && readonly DIM='\033[2m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

# Global state for phase tracking
PROGRESS_PHASE_NAME=""
PROGRESS_PHASE_TOTAL_STEPS=0
PROGRESS_PHASE_START_TIME=0
PROGRESS_CURRENT_STEP=0

# start_phase - Initialize phase tracking and display phase header
#
# Arguments:
#   $1 - Phase name (e.g., "LXD Self-Update", "Backup", "Update libvirt-node")
#   $2 - Total number of steps in this phase
#
# Sets global variables:
#   PROGRESS_PHASE_NAME - Current phase name
#   PROGRESS_PHASE_TOTAL_STEPS - Total steps in phase
#   PROGRESS_PHASE_START_TIME - Timestamp when phase started
#   PROGRESS_CURRENT_STEP - Reset to 0
#
# Example:
#   start_phase "Update Backend" 6
start_phase() {
    local phase_name="$1"
    local total_steps="${2:-1}"

    PROGRESS_PHASE_NAME="$phase_name"
    PROGRESS_PHASE_TOTAL_STEPS="$total_steps"
    PROGRESS_PHASE_START_TIME=$(date +%s)
    PROGRESS_CURRENT_STEP=0

    echo ""
    echo -e "${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} ${BOLD}${phase_name}${NC}"
    echo -e "${BLUE}│${NC} ${DIM}${total_steps} steps${NC}"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# update_step - Display current step with status indicator
#
# Arguments:
#   $1 - Step number (1-based)
#   $2 - Step name/description
#   $3 - Status: "in-progress", "complete", "failed", "skipped"
#
# Output:
#   Displays step with appropriate status indicator and elapsed time
#
# Example:
#   update_step 1 "Checking for updates" "in-progress"
#   update_step 1 "Checking for updates" "complete"
update_step() {
    local step_number="$1"
    local step_name="$2"
    local status="${3:-in-progress}"

    PROGRESS_CURRENT_STEP="$step_number"

    local elapsed=""
    if [[ $PROGRESS_PHASE_START_TIME -gt 0 ]]; then
        elapsed=$(display_elapsed_time "$PROGRESS_PHASE_START_TIME")
    fi

    local status_indicator=""
    local status_color=""

    case "$status" in
        in-progress|running)
            status_indicator="⏳"
            status_color="${CYAN}"
            ;;
        complete|success|done)
            status_indicator="✓"
            status_color="${GREEN}"
            ;;
        failed|error)
            status_indicator="✗"
            status_color="${RED}"
            ;;
        skipped|skip)
            status_indicator="○"
            status_color="${YELLOW}"
            ;;
        *)
            status_indicator="•"
            status_color="${NC}"
            ;;
    esac

    local step_progress="[${step_number}/${PROGRESS_PHASE_TOTAL_STEPS}]"

    if [[ "$status" == "in-progress" || "$status" == "running" ]]; then
        echo -e "${status_color}${status_indicator}${NC} ${DIM}${step_progress}${NC} ${step_name}... ${DIM}(${elapsed})${NC}"
    else
        echo -e "${status_color}${status_indicator}${NC} ${DIM}${step_progress}${NC} ${step_name} ${DIM}(${elapsed})${NC}"
    fi
}

# show_progress_bar - Display ASCII progress bar for long operations
#
# Arguments:
#   $1 - Current progress (0-100 or current count)
#   $2 - Total (100 for percentage, or total count)
#   $3 - Label to display (optional)
#
# Output:
#   [=====>    ] 50% Building...
#
# Example:
#   show_progress_bar 50 100 "Building libvirt-node"
#   show_progress_bar 3 10 "Processing files"
show_progress_bar() {
    local current="$1"
    local total="$2"
    local label="${3:-}"

    # Calculate percentage
    local percentage=0
    if [[ $total -gt 0 ]]; then
        percentage=$((current * 100 / total))
    fi

    # Clamp to 0-100
    [[ $percentage -lt 0 ]] && percentage=0
    [[ $percentage -gt 100 ]] && percentage=100

    # Calculate bar width (20 characters total)
    local bar_width=20
    local filled=$((percentage * bar_width / 100))
    local empty=$((bar_width - filled))

    # Build the bar
    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="="
    done
    if [[ $filled -lt $bar_width ]]; then
        bar+=">"
        empty=$((empty - 1))
    fi
    for ((i=0; i<empty; i++)); do
        bar+=" "
    done

    # Print with carriage return for in-place update
    if [[ -n "$label" ]]; then
        printf "\r${CYAN}[%s]${NC} %3d%% %s" "$bar" "$percentage" "$label"
    else
        printf "\r${CYAN}[%s]${NC} %3d%%" "$bar" "$percentage"
    fi

    # Print newline when complete
    if [[ $percentage -ge 100 ]]; then
        echo ""
    fi
}

# estimate_time - Return estimated duration for common operations
#
# Arguments:
#   $1 - Operation type: "libvirt-node-build", "backend-build", "frontend-build",
#                        "backup", "migration", "health-check"
#
# Returns:
#   String with estimated time range (e.g., "5-10 minutes")
#
# Example:
#   echo "Estimated time: $(estimate_time 'libvirt-node-build')"
estimate_time() {
    local operation="$1"

    case "$operation" in
        libvirt-node-build|rust-build)
            echo "5-10 minutes"
            ;;
        backend-build|typescript-build)
            echo "2-3 minutes"
            ;;
        frontend-build|nextjs-build)
            echo "1-2 minutes"
            ;;
        backup|database-backup)
            echo "1-2 minutes"
            ;;
        migration|prisma-migrate)
            echo "30 seconds - 2 minutes"
            ;;
        health-check|health-checks)
            echo "30 seconds - 1 minute"
            ;;
        npm-install|dependencies)
            echo "1-3 minutes"
            ;;
        codegen|graphql-codegen)
            echo "30 seconds - 1 minute"
            ;;
        git-pull|git-fetch)
            echo "10-30 seconds"
            ;;
        service-restart)
            echo "10-30 seconds"
            ;;
        total-update)
            echo "10-20 minutes"
            ;;
        total-upgrade)
            echo "15-30 minutes"
            ;;
        *)
            echo "varies"
            ;;
    esac
}

# display_elapsed_time - Calculate and format elapsed time
#
# Arguments:
#   $1 - Start timestamp (Unix epoch seconds)
#
# Returns:
#   Formatted string (e.g., "2m 34s", "45s", "1h 5m 12s")
#
# Example:
#   START_TIME=$(date +%s)
#   # ... do work ...
#   echo "Elapsed: $(display_elapsed_time $START_TIME)"
display_elapsed_time() {
    local start_time="$1"
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))

    if [[ $elapsed -lt 0 ]]; then
        echo "0s"
        return
    fi

    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    if [[ $hours -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# phase_summary - Display phase completion summary
#
# Arguments:
#   $1 - Phase name
#   $2 - Start timestamp (Unix epoch seconds)
#   $3 - Status: "success", "failed", "partial"
#
# Output:
#   Formatted summary with total elapsed time and status
#
# Example:
#   phase_summary "Update Backend" $PHASE_START_TIME "success"
phase_summary() {
    local phase_name="$1"
    local start_time="$2"
    local status="${3:-success}"

    local elapsed=$(display_elapsed_time "$start_time")

    local status_indicator=""
    local status_color=""
    local status_text=""

    case "$status" in
        success|complete|done)
            status_indicator="✓"
            status_color="${GREEN}"
            status_text="completed"
            ;;
        failed|error)
            status_indicator="✗"
            status_color="${RED}"
            status_text="failed"
            ;;
        partial|warning)
            status_indicator="⚠"
            status_color="${YELLOW}"
            status_text="completed with warnings"
            ;;
        skipped)
            status_indicator="○"
            status_color="${YELLOW}"
            status_text="skipped"
            ;;
        *)
            status_indicator="•"
            status_color="${NC}"
            status_text="$status"
            ;;
    esac

    echo ""
    echo -e "${status_color}${status_indicator} ${phase_name} ${status_text}${NC} ${DIM}(${elapsed})${NC}"
    echo ""
}

# display_time_estimate - Show estimated time for an operation
#
# Arguments:
#   $1 - Operation type (see estimate_time for valid values)
#   $2 - Optional custom message prefix
#
# Output:
#   Displays estimated time with appropriate formatting
#
# Example:
#   display_time_estimate "libvirt-node-build" "Rust compilation"
display_time_estimate() {
    local operation="$1"
    local prefix="${2:-This may take}"

    local estimate=$(estimate_time "$operation")
    echo -e "${DIM}${prefix} ${estimate}${NC}"
}

# progress_divider - Display a visual divider between sections
#
# Arguments:
#   $1 - Optional label to display in divider
#
# Example:
#   progress_divider
#   progress_divider "Next Steps"
progress_divider() {
    local label="${1:-}"

    if [[ -n "$label" ]]; then
        echo -e "${DIM}─────────────── ${label} ───────────────${NC}"
    else
        echo -e "${DIM}────────────────────────────────────────${NC}"
    fi
}

# spinner_start - Start a spinner animation (for long operations)
# Note: This runs in background and needs to be stopped with spinner_stop
#
# Arguments:
#   $1 - Message to display next to spinner
#
# Example:
#   spinner_start "Building..."
#   # ... long operation ...
#   spinner_stop
SPINNER_PID=""

spinner_start() {
    local message="${1:-Working...}"

    # Kill any existing spinner
    spinner_stop 2>/dev/null

    # Start spinner in background
    (
        local spinchars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r${CYAN}%s${NC} %s" "${spinchars:$i:1}" "$message"
            i=$(( (i + 1) % ${#spinchars} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K"  # Clear the line
    fi
}

# Trap to ensure spinner is stopped on exit (cooperative - preserves existing handlers)
_progress_cleanup() {
    spinner_stop 2>/dev/null
}

# Get existing EXIT trap handler (if any) and chain with our cleanup
_existing_exit_trap=$(trap -p EXIT | sed -n "s/^trap -- '\\(.*\\)' EXIT$/\\1/p" || true)
if [[ -n "$_existing_exit_trap" ]]; then
    # Chain our cleanup with existing handler
    eval "trap '$_existing_exit_trap; _progress_cleanup' EXIT"
else
    # No existing handler, just set ours
    trap '_progress_cleanup' EXIT
fi
unset _existing_exit_trap

# display_operation_header - Display a formatted header for an operation
#
# Arguments:
#   $1 - Operation name
#   $2 - Optional description
#
# Example:
#   display_operation_header "Building Rust Module" "This compiles the native libvirt bindings"
display_operation_header() {
    local name="$1"
    local description="${2:-}"

    echo -e "${BLUE}▶${NC} ${BOLD}${name}${NC}"
    if [[ -n "$description" ]]; then
        echo -e "  ${DIM}${description}${NC}"
    fi
}

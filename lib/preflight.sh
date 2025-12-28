#!/usr/bin/env bash

################################################################################
# Infinibay Pre-flight Checks Library
#
# Purpose: Pre-flight checks before updates/upgrades
#
# Main Functions:
#   - check_containers_running()        : Verify all containers are running
#   - check_uncommitted_changes()       : Check for uncommitted git changes
#   - check_disk_space()                : Verify sufficient disk space (>2GB)
#   - check_backup_directory_writable() : Ensure backup directory is writable
#   - run_all_preflight_checks()        : Run all checks and report results
#
# Usage:
#   source "$(dirname "$0")/lib/preflight.sh"
#   run_all_preflight_checks || { echo "Checks failed"; exit 1; }
#
################################################################################

# Color constants
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

################################################################################
# Check if all Infinibay containers are running (preflight version)
#
# Returns:
#   0 if all containers are running
#   1 if any container is stopped or missing
################################################################################
preflight_check_containers_running() {
    echo -e "${BLUE}Checking container status...${NC}"

    local containers=("infinibay-postgres" "infinibay-backend" "infinibay-frontend")
    local all_running=0
    local stopped_containers=()

    set +e  # Don't exit on error
    for container in "${containers[@]}"; do
        local status
        status=$(lxc list "$container" --format=csv -c s 2>/dev/null)

        if [[ -z "$status" ]]; then
            echo -e "  ${RED}✗${NC} $container: ${RED}NOT FOUND${NC}"
            stopped_containers+=("$container")
            all_running=1
        elif [[ "$status" == "RUNNING" ]]; then
            echo -e "  ${GREEN}✓${NC} $container: ${GREEN}RUNNING${NC}"
        else
            echo -e "  ${RED}✗${NC} $container: ${RED}$status${NC}"
            stopped_containers+=("$container")
            all_running=1
        fi
    done
    set -e

    if [[ $all_running -eq 1 ]]; then
        echo -e "${YELLOW}Hint:${NC} Run './run.sh' to start all containers"
        return 1
    fi

    return 0
}

################################################################################
# Check for uncommitted git changes in all repositories
#
# Checks:
#   - Host: /home/andres/infinibay/lxd
#   - Containers: /opt/infinibay/{backend,frontend,libvirt-node}
#
# Returns:
#   0 if all repositories are clean
#   1 if any repository has uncommitted changes
################################################################################
check_uncommitted_changes() {
    echo -e "${BLUE}Checking for uncommitted changes...${NC}"

    local has_changes=0
    local repos_with_changes=()

    set +e  # Don't exit on error

    # Determine LXD directory path dynamically
    local lxd_dir="${SCRIPT_DIR:-${LXD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

    # Check lxd repo on host
    local lxd_changes
    if [[ ! -d "$lxd_dir" ]]; then
        echo -e "  ${RED}✗${NC} lxd (host): ${RED}Directory does not exist: $lxd_dir${NC}"
        repos_with_changes+=("lxd (host)")
        has_changes=1
    else
        lxd_changes=$(git -C "$lxd_dir" status --porcelain 2>/dev/null)
        if [[ -n "$lxd_changes" ]]; then
            echo -e "  ${YELLOW}⚠${NC} lxd (host): ${YELLOW}Has uncommitted changes${NC}"
            repos_with_changes+=("lxd (host)")
            has_changes=1
        else
            echo -e "  ${GREEN}✓${NC} lxd (host): ${GREEN}Clean${NC}"
        fi
    fi

    # Check backend repo in container
    local backend_changes
    backend_changes=$(lxc exec infinibay-backend -- git -C /opt/infinibay/backend status --porcelain 2>/dev/null)
    if [[ -n "$backend_changes" ]]; then
        echo -e "  ${YELLOW}⚠${NC} backend (container): ${YELLOW}Has uncommitted changes${NC}"
        repos_with_changes+=("backend (container)")
        has_changes=1
    else
        echo -e "  ${GREEN}✓${NC} backend (container): ${GREEN}Clean${NC}"
    fi

    # Check frontend repo in container
    local frontend_changes
    frontend_changes=$(lxc exec infinibay-frontend -- git -C /opt/infinibay/frontend status --porcelain 2>/dev/null)
    if [[ -n "$frontend_changes" ]]; then
        echo -e "  ${YELLOW}⚠${NC} frontend (container): ${YELLOW}Has uncommitted changes${NC}"
        repos_with_changes+=("frontend (container)")
        has_changes=1
    else
        echo -e "  ${GREEN}✓${NC} frontend (container): ${GREEN}Clean${NC}"
    fi

    # Check libvirt-node repo in container
    local libvirt_changes
    libvirt_changes=$(lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node status --porcelain 2>/dev/null)
    if [[ -n "$libvirt_changes" ]]; then
        echo -e "  ${YELLOW}⚠${NC} libvirt-node (container): ${YELLOW}Has uncommitted changes${NC}"
        repos_with_changes+=("libvirt-node (container)")
        has_changes=1
    else
        echo -e "  ${GREEN}✓${NC} libvirt-node (container): ${GREEN}Clean${NC}"
    fi

    set -e

    if [[ $has_changes -eq 1 ]]; then
        echo -e "${YELLOW}Warning:${NC} Uncommitted changes detected in: ${repos_with_changes[*]}"
        echo -e "${YELLOW}Note:${NC} Uncommitted changes will be lost during rollback if update fails"
        return 1
    fi

    return 0
}

################################################################################
# Check available disk space for backups
#
# Requirement: At least 2GB available in /data/backups on postgres container
#
# Returns:
#   0 if sufficient space available (>=2GB)
#   1 if insufficient space
################################################################################
check_disk_space() {
    echo -e "${BLUE}Checking disk space...${NC}"

    set +e  # Don't exit on error

    # Get available space in GB from postgres container
    local df_output
    df_output=$(lxc exec infinibay-postgres -- df -BG /data/backups 2>/dev/null | tail -1)

    if [[ -z "$df_output" ]]; then
        echo -e "  ${RED}✗${NC} Failed to check disk space in infinibay-postgres container"
        set -e
        return 1
    fi

    # Parse available space (4th column in df output)
    local available_gb
    available_gb=$(echo "$df_output" | awk '{print $4}' | sed 's/G//')

    set -e

    # Check if we have at least 2GB
    if [[ $available_gb -ge 2 ]]; then
        echo -e "  ${GREEN}✓${NC} Available space: ${GREEN}${available_gb}GB${NC} (sufficient)"
        return 0
    else
        echo -e "  ${RED}✗${NC} Available space: ${RED}${available_gb}GB${NC} (insufficient, need at least 2GB)"
        echo -e "${YELLOW}Hint:${NC} Clean old backups or free disk space in /data/backups"
        return 1
    fi
}

################################################################################
# Check if backup directory exists and is writable
#
# Checks: /data/backups in infinibay-postgres container
#
# Returns:
#   0 if directory exists and is writable
#   1 if directory missing or not writable
################################################################################
check_backup_directory_writable() {
    echo -e "${BLUE}Checking backup directory...${NC}"

    set +e  # Don't exit on error

    # Check if directory exists
    lxc exec infinibay-postgres -- test -d /data/backups 2>/dev/null
    local dir_exists=$?

    if [[ $dir_exists -ne 0 ]]; then
        echo -e "  ${RED}✗${NC} Backup directory ${RED}/data/backups does not exist${NC}"
        echo -e "${YELLOW}Hint:${NC} Check container setup or run provisioning"
        set -e
        return 1
    fi

    # Check if directory is writable
    lxc exec infinibay-postgres -- test -w /data/backups 2>/dev/null
    local dir_writable=$?

    set -e

    if [[ $dir_writable -ne 0 ]]; then
        echo -e "  ${RED}✗${NC} Backup directory ${RED}is not writable${NC}"
        echo -e "${YELLOW}Hint:${NC} Check container permissions for /data/backups"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} Backup directory: ${GREEN}exists and writable${NC}"
    return 0
}

################################################################################
# Run all pre-flight checks
#
# Executes all check functions in sequence and reports results
#
# Returns:
#   0 if all checks passed
#   1 if any check failed
################################################################################
run_all_preflight_checks() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Running pre-flight checks...${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    local failed_checks=0
    local failed_check_names=()

    # Run container status check
    if ! preflight_check_containers_running; then
        ((failed_checks++))
        failed_check_names+=("Container status")
    fi
    echo ""

    # Run uncommitted changes check
    if ! check_uncommitted_changes; then
        ((failed_checks++))
        failed_check_names+=("Uncommitted changes")
    fi
    echo ""

    # Run disk space check
    if ! check_disk_space; then
        ((failed_checks++))
        failed_check_names+=("Disk space")
    fi
    echo ""

    # Run backup directory check
    if ! check_backup_directory_writable; then
        ((failed_checks++))
        failed_check_names+=("Backup directory")
    fi
    echo ""

    # Print summary
    echo -e "${BLUE}========================================${NC}"
    if [[ $failed_checks -eq 0 ]]; then
        echo -e "${GREEN}✓ All pre-flight checks passed${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}✗ Pre-flight checks failed: $failed_checks check(s)${NC}"
        echo -e "${RED}  Failed checks: ${failed_check_names[*]}${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        return 1
    fi
}

#!/usr/bin/env bash

# error-messages.sh - Infinibay Enhanced Error Message Library
#
# This library provides context-aware error messages with troubleshooting guidance
# for update and upgrade operations. Each function displays a formatted error with
# common causes and actionable next steps.
#
# Main Functions:
#   error_build_failed <component> <log_path> <backup_path>
#   error_migration_failed <migration_name> <backup_path>
#   error_preflight_failed <check_name> <reason> <hint>
#   error_health_check_failed <service_name> <backup_path>
#   error_git_operation_failed <operation> <repo> <reason>
#   error_npm_operation_failed <operation> <component> <reason>
#
# Usage:
#   source lib/error-messages.sh
#   error_build_failed "backend" "/opt/infinibay/backend/build.log" "/data/backups/update_20250124"

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

# error_header - Display formatted error header
#
# Arguments:
#   $1 - Error title
#
# Internal helper function
_error_header() {
    local title="$1"
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC} ${BOLD}${RED}ERROR: ${title}${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# _error_section - Display a section within error message
#
# Arguments:
#   $1 - Section title
#   $2 - Color (optional, defaults to YELLOW)
_error_section() {
    local title="$1"
    local color="${2:-$YELLOW}"
    echo -e "${color}${title}:${NC}"
}

# error_build_failed - Display detailed build failure message
#
# Arguments:
#   $1 - Component that failed: "libvirt-node", "backend", "frontend"
#   $2 - Path to build log (optional)
#   $3 - Backup path for rollback reference (optional)
#
# Example:
#   error_build_failed "backend" "/opt/infinibay/backend/build.log" "/data/backups/update_20250124"
error_build_failed() {
    local component="$1"
    local log_path="${2:-}"
    local backup_path="${3:-}"

    _error_header "${component} Build Failed"

    echo -e "${DIM}The ${component} build process encountered an error and could not complete.${NC}"
    echo -e "${DIM}Your system will be automatically rolled back to the previous state.${NC}"
    echo ""

    _error_section "Common Causes" "$YELLOW"
    case "$component" in
        libvirt-node|libvirt)
            echo "  1. Rust toolchain version mismatch"
            echo "  2. Missing libvirt development headers"
            echo "  3. System dependencies not installed"
            echo "  4. Insufficient disk space for compilation"
            echo "  5. Memory exhaustion during Rust compilation"
            ;;
        backend)
            echo "  1. TypeScript compilation errors"
            echo "  2. Breaking changes in GraphQL schema"
            echo "  3. Missing or incompatible npm dependencies"
            echo "  4. Prisma schema validation errors"
            echo "  5. Node.js version incompatibility"
            ;;
        frontend)
            echo "  1. GraphQL codegen errors (schema mismatch with backend)"
            echo "  2. TypeScript/JSX compilation errors"
            echo "  3. Next.js build configuration issues"
            echo "  4. Missing or incompatible npm dependencies"
            echo "  5. Environment variable configuration errors"
            ;;
        *)
            echo "  1. Compilation errors in source code"
            echo "  2. Missing dependencies"
            echo "  3. Configuration issues"
            ;;
    esac
    echo ""

    _error_section "Next Steps" "$BLUE"
    echo "  1. Check the build logs for specific error messages"
    if [[ -n "$log_path" ]]; then
        echo -e "     ${CYAN}lxc exec infinibay-${component} -- cat ${log_path}${NC}"
    fi
    echo "  2. If this is a known issue, wait for a fix from developers"
    echo "  3. Report the issue with build logs if it persists"
    echo -e "     ${CYAN}https://github.com/infinibay/infinibay/issues${NC}"
    echo ""

    if [[ -n "$backup_path" ]]; then
        _error_section "Backup Information" "$GREEN"
        echo -e "  Your system backup is preserved at: ${CYAN}${backup_path}${NC}"
        echo "  The automatic rollback will restore your system to this state."
        echo ""
    fi

    _error_section "Troubleshooting Commands" "$CYAN"
    case "$component" in
        libvirt-node|libvirt)
            echo -e "  ${DIM}# Check Rust version${NC}"
            echo -e "  lxc exec infinibay-backend -- su - infinibay -c 'rustc --version'"
            echo -e "  ${DIM}# Check libvirt headers${NC}"
            echo -e "  lxc exec infinibay-backend -- dpkg -l | grep libvirt-dev"
            echo -e "  ${DIM}# Check disk space${NC}"
            echo -e "  lxc exec infinibay-backend -- df -h /opt/infinibay"
            ;;
        backend)
            echo -e "  ${DIM}# Check Node.js version${NC}"
            echo -e "  lxc exec infinibay-backend -- node --version"
            echo -e "  ${DIM}# Check TypeScript errors${NC}"
            echo -e "  lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && npx tsc --noEmit'"
            echo -e "  ${DIM}# Check Prisma schema${NC}"
            echo -e "  lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && npx prisma validate'"
            ;;
        frontend)
            echo -e "  ${DIM}# Check Node.js version${NC}"
            echo -e "  lxc exec infinibay-frontend -- node --version"
            echo -e "  ${DIM}# Regenerate GraphQL hooks${NC}"
            echo -e "  lxc exec infinibay-frontend -- su - infinibay -c 'cd /opt/infinibay/frontend && npm run codegen'"
            echo -e "  ${DIM}# Check for TypeScript errors${NC}"
            echo -e "  lxc exec infinibay-frontend -- su - infinibay -c 'cd /opt/infinibay/frontend && npx tsc --noEmit'"
            ;;
    esac
    echo ""
}

# error_migration_failed - Display database migration failure message
#
# Arguments:
#   $1 - Migration name or type: "prisma", "data", specific migration name
#   $2 - Backup path for rollback reference
#
# Example:
#   error_migration_failed "prisma" "/data/backups/update_20250124"
error_migration_failed() {
    local migration_name="$1"
    local backup_path="${2:-}"

    _error_header "Database Migration Failed"

    echo -e "${RED}${BOLD}CRITICAL:${NC} ${DIM}Database migration encountered an error.${NC}"
    echo -e "${DIM}This is a critical failure that requires immediate attention.${NC}"
    echo -e "${DIM}Your system will be automatically rolled back to preserve data integrity.${NC}"
    echo ""

    _error_section "What Happened" "$YELLOW"
    case "$migration_name" in
        prisma|schema)
            echo "  The Prisma schema migration failed to apply database changes."
            echo "  This typically means the database could not be modified to match"
            echo "  the new schema structure."
            ;;
        data)
            echo "  A data migration script failed during execution."
            echo "  This means existing data could not be transformed to the new format."
            ;;
        *)
            echo "  Migration '${migration_name}' failed during execution."
            ;;
    esac
    echo ""

    _error_section "Common Causes" "$YELLOW"
    echo "  1. Schema conflicts with existing data"
    echo "  2. Foreign key constraint violations"
    echo "  3. Data type incompatibilities"
    echo "  4. Unique constraint violations on existing data"
    echo "  5. Timeout during large data transformations"
    echo "  6. Database connection issues"
    echo ""

    _error_section "Next Steps" "$BLUE"
    echo -e "  ${RED}${BOLD}1. DO NOT retry the update/upgrade manually${NC}"
    echo "  2. Wait for automatic rollback to complete"
    echo "  3. Check migration logs for specific errors:"
    echo -e "     ${CYAN}lxc exec infinibay-backend -- cat /opt/infinibay/backend/prisma/migrations/migration.log${NC}"
    echo "  4. Contact support with the error details"
    echo -e "     ${CYAN}https://github.com/infinibay/infinibay/issues${NC}"
    echo ""

    if [[ -n "$backup_path" ]]; then
        _error_section "Data Safety" "$GREEN"
        echo -e "  ${GREEN}Your data is safe.${NC} A full backup was created before migration:"
        echo -e "  ${CYAN}${backup_path}${NC}"
        echo ""
        echo "  The automatic rollback will restore your database to this state."
        echo "  No data has been lost."
        echo ""
    fi

    _error_section "Troubleshooting Commands" "$CYAN"
    echo -e "  ${DIM}# Check migration status${NC}"
    echo -e "  lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && npx prisma migrate status'"
    echo -e "  ${DIM}# Check database connection${NC}"
    echo -e "  lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && npx prisma db pull --print'"
    echo -e "  ${DIM}# View recent PostgreSQL logs${NC}"
    echo -e "  lxc exec infinibay-postgres -- journalctl -u postgresql -n 50"
    echo ""
}

# error_preflight_failed - Display pre-flight check failure message
#
# Arguments:
#   $1 - Check name: "containers", "uncommitted-changes", "disk-space", "backup-writable"
#   $2 - Specific reason for failure
#   $3 - Hint for resolution (optional)
#
# Example:
#   error_preflight_failed "containers" "infinibay-backend is not running" "Run: ./run.sh apply"
error_preflight_failed() {
    local check_name="$1"
    local reason="$2"
    local hint="${3:-}"

    _error_header "Pre-flight Check Failed"

    echo -e "${DIM}The update/upgrade cannot proceed because a pre-flight check failed.${NC}"
    echo -e "${DIM}Please resolve the issue and try again.${NC}"
    echo ""

    _error_section "Failed Check" "$YELLOW"
    echo -e "  ${BOLD}${check_name}${NC}"
    echo ""

    _error_section "Reason" "$YELLOW"
    echo "  ${reason}"
    echo ""

    case "$check_name" in
        containers|container-status)
            _error_section "Resolution" "$BLUE"
            echo "  1. Check which containers are not running:"
            echo -e "     ${CYAN}./run.sh status${NC}"
            echo "  2. Start all containers:"
            echo -e "     ${CYAN}./run.sh apply${NC}"
            echo "  3. If containers fail to start, check logs:"
            echo -e "     ${CYAN}./run.sh logs <container-name>${NC}"
            ;;
        uncommitted-changes|git-status)
            _error_section "Resolution" "$BLUE"
            echo "  1. Identify uncommitted changes:"
            echo -e "     ${CYAN}lxc exec infinibay-backend -- git -C /opt/infinibay/backend status${NC}"
            echo "  2. Either commit the changes:"
            echo -e "     ${CYAN}lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && git add . && git commit -m \"WIP\"'${NC}"
            echo "  3. Or stash them for later:"
            echo -e "     ${CYAN}lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && git stash'${NC}"
            ;;
        disk-space|storage)
            _error_section "Resolution" "$BLUE"
            echo "  1. Check current disk usage:"
            echo -e "     ${CYAN}df -h /data${NC}"
            echo "  2. Clean up old backups:"
            echo -e "     ${CYAN}./run.sh backup --clean${NC}"
            echo "  3. Remove unused Docker/LXD images:"
            echo -e "     ${CYAN}lxc image list${NC}"
            echo "  4. Check for large log files:"
            echo -e "     ${CYAN}lxc exec infinibay-backend -- du -sh /var/log/*${NC}"
            ;;
        backup-writable|backup-directory)
            _error_section "Resolution" "$BLUE"
            echo "  1. Check backup directory permissions:"
            echo -e "     ${CYAN}lxc exec infinibay-postgres -- ls -ld /data/backups${NC}"
            echo "  2. Fix permissions if needed:"
            echo -e "     ${CYAN}lxc exec infinibay-postgres -- chown -R postgres:postgres /data/backups${NC}"
            echo -e "     ${CYAN}lxc exec infinibay-postgres -- chmod 755 /data/backups${NC}"
            echo "  3. Ensure storage device is not full or read-only"
            ;;
        database|postgres)
            _error_section "Resolution" "$BLUE"
            echo "  1. Check PostgreSQL service status:"
            echo -e "     ${CYAN}lxc exec infinibay-postgres -- systemctl status postgresql${NC}"
            echo "  2. Check PostgreSQL logs:"
            echo -e "     ${CYAN}lxc exec infinibay-postgres -- journalctl -u postgresql -n 50${NC}"
            echo "  3. Test database connection:"
            echo -e "     ${CYAN}lxc exec infinibay-postgres -- su - postgres -c \"psql -c 'SELECT 1'\"${NC}"
            ;;
        *)
            if [[ -n "$hint" ]]; then
                _error_section "Hint" "$BLUE"
                echo "  ${hint}"
            fi
            ;;
    esac
    echo ""
}

# error_health_check_failed - Display health check failure message
#
# Arguments:
#   $1 - Service name: "postgres", "backend", "frontend"
#   $2 - Backup path for rollback reference (optional)
#
# Example:
#   error_health_check_failed "backend" "/data/backups/update_20250124"
error_health_check_failed() {
    local service_name="$1"
    local backup_path="${2:-}"

    _error_header "${service_name} Health Check Failed"

    echo -e "${DIM}The ${service_name} service failed health checks after update.${NC}"
    echo -e "${DIM}Your system will be automatically rolled back to the previous state.${NC}"
    echo ""

    _error_section "What This Means" "$YELLOW"
    case "$service_name" in
        postgres|postgresql|database)
            echo "  The PostgreSQL database is not responding correctly."
            echo "  This could indicate a startup failure, configuration issue,"
            echo "  or resource exhaustion."
            ;;
        backend|api)
            echo "  The backend API service is not responding to requests."
            echo "  This typically means the Node.js server failed to start"
            echo "  or crashed during initialization."
            ;;
        frontend|web)
            echo "  The frontend web service is not serving pages correctly."
            echo "  This could indicate a Next.js server startup failure"
            echo "  or configuration issue."
            ;;
        system|services|all)
            echo "  One or more Infinibay services failed health checks."
            echo "  This could affect database, backend, or frontend services."
            echo "  Check individual service logs for specific failures."
            ;;
        *)
            echo "  The ${service_name} service is not responding correctly."
            echo "  Check service logs for specific error details."
            ;;
    esac
    echo ""

    _error_section "Common Causes" "$YELLOW"
    case "$service_name" in
        postgres|postgresql|database)
            echo "  1. Database configuration errors"
            echo "  2. Insufficient memory or disk space"
            echo "  3. Port conflict (5432 in use)"
            echo "  4. Corrupted data files"
            echo "  5. Authentication configuration issues"
            ;;
        backend|api)
            echo "  1. Missing environment variables"
            echo "  2. Database connection failure"
            echo "  3. Port conflict (4000 in use)"
            echo "  4. Uncaught exceptions during startup"
            echo "  5. Missing dependencies or build artifacts"
            ;;
        frontend|web)
            echo "  1. Port conflict (3000 in use)"
            echo "  2. Missing build artifacts (.next directory)"
            echo "  3. Environment configuration errors"
            echo "  4. Memory exhaustion"
            ;;
        system|services|all)
            echo "  1. Service startup ordering issues"
            echo "  2. Network connectivity between containers"
            echo "  3. Resource exhaustion (memory, disk)"
            echo "  4. Configuration inconsistencies"
            echo "  5. Container orchestration failures"
            ;;
        *)
            echo "  1. Service configuration errors"
            echo "  2. Resource exhaustion"
            echo "  3. Startup failures"
            ;;
    esac
    echo ""

    _error_section "Troubleshooting Commands" "$CYAN"
    case "$service_name" in
        postgres|postgresql|database)
            echo -e "  ${DIM}# Check service status${NC}"
            echo -e "  lxc exec infinibay-postgres -- systemctl status postgresql"
            echo -e "  ${DIM}# Check logs${NC}"
            echo -e "  lxc exec infinibay-postgres -- journalctl -u postgresql -n 50"
            echo -e "  ${DIM}# Test connection${NC}"
            echo -e "  lxc exec infinibay-postgres -- su - postgres -c \"psql -c 'SELECT 1'\""
            ;;
        backend|api)
            echo -e "  ${DIM}# Check service status${NC}"
            echo -e "  lxc exec infinibay-backend -- systemctl status infinibay-backend"
            echo -e "  ${DIM}# Check logs${NC}"
            echo -e "  lxc exec infinibay-backend -- journalctl -u infinibay-backend -n 50"
            echo -e "  ${DIM}# Test GraphQL endpoint${NC}"
            echo -e "  curl -s http://localhost:4000/graphql -H 'Content-Type: application/json' -d '{\"query\":\"{__schema{types{name}}}\"}'"
            ;;
        frontend|web)
            echo -e "  ${DIM}# Check service status${NC}"
            echo -e "  lxc exec infinibay-frontend -- systemctl status infinibay-frontend"
            echo -e "  ${DIM}# Check logs${NC}"
            echo -e "  lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -n 50"
            echo -e "  ${DIM}# Test HTTP endpoint${NC}"
            echo -e "  curl -sI http://localhost:3000 | head -1"
            ;;
        system|services|all)
            echo -e "  ${DIM}# Check all container status${NC}"
            echo -e "  ./run.sh status"
            echo -e "  ${DIM}# Check individual services${NC}"
            echo -e "  lxc exec infinibay-postgres -- systemctl status postgresql"
            echo -e "  lxc exec infinibay-backend -- systemctl status infinibay-backend"
            echo -e "  lxc exec infinibay-frontend -- systemctl status infinibay-frontend"
            echo -e "  ${DIM}# View all logs${NC}"
            echo -e "  ./run.sh logs backend"
            ;;
        *)
            echo -e "  ${DIM}# Check container status${NC}"
            echo -e "  ./run.sh status"
            echo -e "  ${DIM}# Check service logs${NC}"
            echo -e "  ./run.sh logs ${service_name}"
            ;;
    esac
    echo ""

    if [[ -n "$backup_path" ]]; then
        _error_section "Automatic Rollback" "$GREEN"
        echo -e "  Your system will be rolled back to: ${CYAN}${backup_path}${NC}"
        echo "  This process will:"
        echo "  1. Restore the database to its previous state"
        echo "  2. Reset code to previous commits"
        echo "  3. Rebuild all services from scratch"
        echo "  4. Restart all services"
        echo "  5. Verify system health"
        echo ""
    fi
}

# error_git_operation_failed - Display git operation failure message
#
# Arguments:
#   $1 - Operation: "fetch", "pull", "reset", "checkout"
#   $2 - Repository: "lxd", "backend", "frontend", "libvirt-node"
#   $3 - Reason (optional)
#
# Example:
#   error_git_operation_failed "pull" "backend" "merge conflict"
error_git_operation_failed() {
    local operation="$1"
    local repo="$2"
    local reason="${3:-}"

    _error_header "Git ${operation^} Failed"

    echo -e "${DIM}Failed to ${operation} updates for the ${repo} repository.${NC}"
    echo ""

    if [[ -n "$reason" ]]; then
        _error_section "Reason" "$YELLOW"
        echo "  ${reason}"
        echo ""
    fi

    _error_section "Common Causes" "$YELLOW"
    case "$operation" in
        fetch)
            echo "  1. Network connectivity issues"
            echo "  2. Git remote not configured correctly"
            echo "  3. Authentication/SSH key problems"
            echo "  4. GitHub/GitLab service unavailable"
            ;;
        pull)
            echo "  1. Merge conflicts with local changes"
            echo "  2. Detached HEAD state"
            echo "  3. Network connectivity issues"
            echo "  4. Branch protection or permissions"
            echo "  5. Corrupted local repository"
            ;;
        reset)
            echo "  1. Corrupted git index"
            echo "  2. File system permissions issues"
            echo "  3. Disk full"
            ;;
        checkout)
            echo "  1. Uncommitted changes blocking checkout"
            echo "  2. Branch or commit does not exist"
            echo "  3. Corrupted repository state"
            ;;
    esac
    echo ""

    _error_section "Resolution Steps" "$BLUE"
    local container="infinibay-backend"
    local path="/opt/infinibay/${repo}"

    if [[ "$repo" == "frontend" ]]; then
        container="infinibay-frontend"
    elif [[ "$repo" == "lxd" ]]; then
        container=""
        path="$(pwd)"
    fi

    if [[ -n "$container" ]]; then
        echo "  1. Check git status:"
        echo -e "     ${CYAN}lxc exec ${container} -- git -C ${path} status${NC}"
        echo "  2. Check remote configuration:"
        echo -e "     ${CYAN}lxc exec ${container} -- git -C ${path} remote -v${NC}"
        echo "  3. Try manual ${operation}:"
        echo -e "     ${CYAN}lxc exec ${container} -- git -C ${path} ${operation} origin main${NC}"
        if [[ "$operation" == "pull" ]]; then
            echo "  4. If conflicts exist, resolve or reset:"
            echo -e "     ${CYAN}lxc exec ${container} -- git -C ${path} reset --hard origin/main${NC}"
        fi
    else
        echo "  1. Check git status:"
        echo -e "     ${CYAN}git -C ${path} status${NC}"
        echo "  2. Check remote configuration:"
        echo -e "     ${CYAN}git -C ${path} remote -v${NC}"
        echo "  3. Try manual ${operation}:"
        echo -e "     ${CYAN}git -C ${path} ${operation} origin main${NC}"
    fi
    echo ""
}

# error_npm_operation_failed - Display npm operation failure message
#
# Arguments:
#   $1 - Operation: "install", "build", "pack", "run"
#   $2 - Component: "backend", "frontend", "libvirt-node"
#   $3 - Reason (optional)
#
# Example:
#   error_npm_operation_failed "install" "backend" "ERESOLVE dependency conflict"
error_npm_operation_failed() {
    local operation="$1"
    local component="$2"
    local reason="${3:-}"

    _error_header "npm ${operation} Failed"

    echo -e "${DIM}The npm ${operation} command failed for ${component}.${NC}"
    echo ""

    if [[ -n "$reason" ]]; then
        _error_section "Error Message" "$YELLOW"
        echo "  ${reason}"
        echo ""
    fi

    _error_section "Common Causes" "$YELLOW"
    case "$operation" in
        install)
            echo "  1. Dependency version conflicts (ERESOLVE)"
            echo "  2. Network timeout downloading packages"
            echo "  3. Corrupted package-lock.json"
            echo "  4. npm cache corruption"
            echo "  5. Node.js version incompatibility"
            echo "  6. Disk space exhaustion"
            ;;
        build)
            echo "  1. TypeScript compilation errors"
            echo "  2. Missing dependencies (run npm install first)"
            echo "  3. Build script configuration errors"
            echo "  4. Memory exhaustion during build"
            echo "  5. Missing environment variables"
            ;;
        pack)
            echo "  1. Missing required files in package.json"
            echo "  2. Invalid package.json configuration"
            echo "  3. Build artifacts missing"
            ;;
        run)
            echo "  1. Script not defined in package.json"
            echo "  2. Script execution error"
            echo "  3. Missing dependencies"
            ;;
    esac
    echo ""

    _error_section "Resolution Steps" "$BLUE"
    local container="infinibay-backend"
    local path="/opt/infinibay/${component}"

    if [[ "$component" == "frontend" ]]; then
        container="infinibay-frontend"
    fi

    echo "  1. Check npm and Node.js versions:"
    echo -e "     ${CYAN}lxc exec ${container} -- node --version${NC}"
    echo -e "     ${CYAN}lxc exec ${container} -- npm --version${NC}"

    case "$operation" in
        install)
            echo "  2. Clear npm cache and reinstall:"
            echo -e "     ${CYAN}lxc exec ${container} -- npm cache clean --force${NC}"
            echo -e "     ${CYAN}lxc exec ${container} -- su - infinibay -c 'cd ${path} && rm -rf node_modules package-lock.json && npm install'${NC}"
            echo "  3. If dependency conflicts persist, try:"
            echo -e "     ${CYAN}lxc exec ${container} -- su - infinibay -c 'cd ${path} && npm install --legacy-peer-deps'${NC}"
            ;;
        build)
            echo "  2. Check for TypeScript errors:"
            echo -e "     ${CYAN}lxc exec ${container} -- su - infinibay -c 'cd ${path} && npx tsc --noEmit'${NC}"
            echo "  3. Ensure dependencies are installed:"
            echo -e "     ${CYAN}lxc exec ${container} -- su - infinibay -c 'cd ${path} && npm install'${NC}"
            echo "  4. Try clean build:"
            echo -e "     ${CYAN}lxc exec ${container} -- su - infinibay -c 'cd ${path} && rm -rf dist && npm run build'${NC}"
            ;;
        pack)
            echo "  2. Verify package.json configuration:"
            echo -e "     ${CYAN}lxc exec ${container} -- cat ${path}/package.json | jq '.files'${NC}"
            echo "  3. Ensure build completed successfully:"
            echo -e "     ${CYAN}lxc exec ${container} -- ls -la ${path}/dist${NC}"
            ;;
    esac
    echo ""
}

# error_service_restart_failed - Display service restart failure message
#
# Arguments:
#   $1 - Service name: "backend", "frontend"
#   $2 - Backup path (optional)
#
# Example:
#   error_service_restart_failed "backend" "/data/backups/update_20250124"
error_service_restart_failed() {
    local service_name="$1"
    local backup_path="${2:-}"

    _error_header "${service_name} Service Restart Failed"

    echo -e "${DIM}The ${service_name} service failed to restart after update.${NC}"
    echo -e "${DIM}Your system will be automatically rolled back to the previous state.${NC}"
    echo ""

    _error_section "Troubleshooting Commands" "$CYAN"
    local container="infinibay-${service_name}"
    local service="infinibay-${service_name}"

    echo -e "  ${DIM}# Check service status${NC}"
    echo -e "  lxc exec ${container} -- systemctl status ${service}"
    echo -e "  ${DIM}# Check service logs${NC}"
    echo -e "  lxc exec ${container} -- journalctl -u ${service} -n 100"
    echo -e "  ${DIM}# Try manual restart${NC}"
    echo -e "  lxc exec ${container} -- systemctl restart ${service}"
    echo ""

    if [[ -n "$backup_path" ]]; then
        _error_section "Automatic Rollback" "$GREEN"
        echo -e "  Your system will be rolled back to: ${CYAN}${backup_path}${NC}"
        echo ""
    fi
}

# error_rollback_failed - Display critical rollback failure message
#
# Arguments:
#   $1 - What failed during rollback
#   $2 - Backup path
#
# Example:
#   error_rollback_failed "database restore" "/data/backups/update_20250124"
error_rollback_failed() {
    local what_failed="$1"
    local backup_path="${2:-}"

    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║                    CRITICAL FAILURE                          ║${NC}"
    echo -e "${RED}${BOLD}║              Automatic Rollback Failed                       ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${RED}The automatic rollback process failed during: ${what_failed}${NC}"
    echo ""
    echo -e "${YELLOW}Your system may be in an inconsistent state.${NC}"
    echo ""

    _error_section "Immediate Actions Required" "$RED"
    echo "  1. DO NOT attempt further updates or upgrades"
    echo "  2. Contact support immediately with full logs"
    echo "  3. Consider manual recovery from backup"
    echo ""

    if [[ -n "$backup_path" ]]; then
        _error_section "Manual Recovery" "$BLUE"
        echo "  Your backup is preserved at: ${backup_path}"
        echo ""
        echo "  To manually restore the database:"
        echo -e "  ${CYAN}lxc exec infinibay-postgres -- su - postgres -c \"dropdb infinibay\"${NC}"
        echo -e "  ${CYAN}lxc exec infinibay-postgres -- su - postgres -c \"createdb infinibay\"${NC}"
        echo -e "  ${CYAN}lxc exec infinibay-postgres -- su - postgres -c \"psql infinibay < ${backup_path}/infinibay_backup.sql\"${NC}"
        echo ""
    fi

    _error_section "Support Contact" "$CYAN"
    echo -e "  GitHub Issues: ${CYAN}https://github.com/infinibay/infinibay/issues${NC}"
    echo "  Include: Error messages, backup path, and full terminal output"
    echo ""
}

# display_rollback_notice - Display notice that rollback is starting
#
# Arguments:
#   $1 - Backup path being restored
#
# Example:
#   display_rollback_notice "/data/backups/update_20250124"
display_rollback_notice() {
    local backup_path="$1"

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              Initiating Automatic Rollback                   ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${DIM}Restoring system from backup: ${backup_path}${NC}"
    echo ""
    echo "This process will:"
    echo "  1. Stop affected services"
    echo "  2. Restore database from backup"
    echo "  3. Reset code repositories to previous commits"
    echo "  4. Rebuild all affected components"
    echo "  5. Restart services"
    echo "  6. Verify system health"
    echo ""
    echo -e "${YELLOW}Please do not interrupt this process.${NC}"
    echo ""
}

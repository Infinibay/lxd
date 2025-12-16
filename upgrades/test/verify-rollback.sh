#!/usr/bin/env bash

# verify-rollback.sh - Verifies system was properly restored after rollback
#
# This script performs comprehensive verification that the system was
# correctly restored to its pre-upgrade state after a rollback.
#
# Usage:
#   ./verify-rollback.sh                     # Verify current state matches test-base
#   ./verify-rollback.sh /path/to/backup     # Compare against specific backup
#   ./verify-rollback.sh --expected test-base # Verify version matches expected

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXD_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
UPGRADES_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$UPGRADES_DIR/current_version.txt"

# Default expected version
EXPECTED_VERSION="test-base"
BACKUP_PATH=""
VERBOSE=false

# Verification results
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --expected|-e)
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [BACKUP_PATH]"
            echo ""
            echo "Options:"
            echo "  --expected, -e VERSION  Expected version (default: test-base)"
            echo "  --verbose, -v           Show detailed output"
            echo "  --help, -h              Show this help"
            echo ""
            echo "Arguments:"
            echo "  BACKUP_PATH             Path to backup to compare against"
            exit 0
            ;;
        /*)
            BACKUP_PATH="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((CHECKS_PASSED++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((CHECKS_FAILED++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((CHECKS_SKIPPED++))
}

log_verbose() {
    if $VERBOSE; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Check version file
check_version() {
    log_info "Checking version..."

    local current_version
    current_version=$(cat "$VERSION_FILE" 2>/dev/null || echo "NOT_FOUND")

    if [[ "$current_version" == "$EXPECTED_VERSION" ]]; then
        log_success "Version: $current_version (matches expected: $EXPECTED_VERSION)"
    else
        log_error "Version: $current_version (expected: $EXPECTED_VERSION)"
    fi
}

# Check all services are active
check_services() {
    log_info "Checking services..."

    # Check containers are running
    for container in infinibay-postgres infinibay-redis infinibay-backend infinibay-frontend; do
        local status
        status=$(lxc list "$container" --format=csv -c s 2>/dev/null || echo "MISSING")

        if [[ "$status" == "RUNNING" ]]; then
            log_success "Container $container: RUNNING"
        else
            log_error "Container $container: $status"
        fi
    done
}

# Check database connectivity
check_database() {
    log_info "Checking database connectivity..."

    if lxc exec infinibay-postgres -- su - postgres -c "psql -c 'SELECT 1' infinibay" > /dev/null 2>&1; then
        log_success "Database: PostgreSQL connection successful"
    else
        log_error "Database: PostgreSQL connection failed"
    fi

    # Check Redis
    if lxc exec infinibay-redis -- redis-cli ping > /dev/null 2>&1; then
        log_success "Database: Redis connection successful"
    else
        log_error "Database: Redis connection failed"
    fi
}

# Check backend health
check_backend_health() {
    log_info "Checking backend health..."

    # Check systemd service (if applicable)
    local service_status
    service_status=$(lxc exec infinibay-backend -- systemctl is-active infinibay-backend 2>/dev/null || echo "unknown")

    if [[ "$service_status" == "active" ]]; then
        log_success "Backend service: active"
    elif [[ "$service_status" == "unknown" ]]; then
        log_skip "Backend service: systemd status check skipped (service may use different name)"
    else
        log_error "Backend service: $service_status"
    fi

    # Check health endpoint (if running)
    # This would require the backend to be actually running with proper networking
    log_verbose "Backend health endpoint check skipped (requires network access)"
}

# Check frontend health
check_frontend_health() {
    log_info "Checking frontend health..."

    # Check systemd service (if applicable)
    local service_status
    service_status=$(lxc exec infinibay-frontend -- systemctl is-active infinibay-frontend 2>/dev/null || echo "unknown")

    if [[ "$service_status" == "active" ]]; then
        log_success "Frontend service: active"
    elif [[ "$service_status" == "unknown" ]]; then
        log_skip "Frontend service: systemd status check skipped (service may use different name)"
    else
        log_error "Frontend service: $service_status"
    fi
}

# Check git commits match backup (if backup provided)
check_git_commits() {
    if [[ -z "$BACKUP_PATH" ]]; then
        log_skip "Git commits: no backup path provided for comparison"
        return
    fi

    log_info "Checking git commits against backup..."

    # Check if backup has commit files
    if [[ ! -d "$BACKUP_PATH" ]]; then
        log_error "Git commits: backup path not found: $BACKUP_PATH"
        return
    fi

    # Check backend commit
    if [[ -f "$BACKUP_PATH/commits/backend.txt" ]]; then
        local backup_commit
        local current_commit
        backup_commit=$(cat "$BACKUP_PATH/commits/backend.txt" 2>/dev/null)
        current_commit=$(lxc exec infinibay-backend -- git -C /app rev-parse HEAD 2>/dev/null || echo "unknown")

        if [[ "$backup_commit" == "$current_commit" ]]; then
            log_success "Backend commit: matches backup ($current_commit)"
        else
            log_error "Backend commit: mismatch (backup: $backup_commit, current: $current_commit)"
        fi
    else
        log_skip "Backend commit: no backup commit file found"
    fi

    # Check frontend commit
    if [[ -f "$BACKUP_PATH/commits/frontend.txt" ]]; then
        local backup_commit
        local current_commit
        backup_commit=$(cat "$BACKUP_PATH/commits/frontend.txt" 2>/dev/null)
        current_commit=$(lxc exec infinibay-frontend -- git -C /app rev-parse HEAD 2>/dev/null || echo "unknown")

        if [[ "$backup_commit" == "$current_commit" ]]; then
            log_success "Frontend commit: matches backup ($current_commit)"
        else
            log_error "Frontend commit: mismatch (backup: $backup_commit, current: $current_commit)"
        fi
    else
        log_skip "Frontend commit: no backup commit file found"
    fi
}

# Check for uncommitted changes
check_uncommitted_changes() {
    log_info "Checking for uncommitted changes..."

    # Check backend
    local backend_status
    backend_status=$(lxc exec infinibay-backend -- git -C /app status --porcelain 2>/dev/null | wc -l)

    if [[ "$backend_status" -eq 0 ]]; then
        log_success "Backend repo: clean (no uncommitted changes)"
    else
        log_warning "Backend repo: has uncommitted changes ($backend_status files)"
    fi

    # Check frontend
    local frontend_status
    frontend_status=$(lxc exec infinibay-frontend -- git -C /app status --porcelain 2>/dev/null | wc -l)

    if [[ "$frontend_status" -eq 0 ]]; then
        log_success "Frontend repo: clean (no uncommitted changes)"
    else
        log_warning "Frontend repo: has uncommitted changes ($frontend_status files)"
    fi
}

# Check data migration registry
# Note: The registry file location is derived from repository root for portability.
# It is located at: <repo_root>/backend/prisma/data-migrations/registry.json
check_migration_registry() {
    log_info "Checking data migration registry..."

    # Derive registry path relative to repository root (LXD_DIR is <repo>/lxd)
    local repo_root
    repo_root="$(dirname "$LXD_DIR")"
    local registry_file="$repo_root/backend/prisma/data-migrations/registry.json"

    log_verbose "Registry file path: $registry_file"

    if [[ ! -f "$registry_file" ]]; then
        log_skip "Migration registry: file not found at $registry_file"
        return
    fi

    # Check registry is valid JSON
    if jq empty "$registry_file" 2>/dev/null; then
        log_success "Migration registry: valid JSON"
    else
        log_error "Migration registry: invalid JSON"
        return
    fi

    # Count applied migrations
    local migration_count
    migration_count=$(jq '.appliedMigrations | length' "$registry_file" 2>/dev/null || echo "0")
    log_verbose "Migration registry: $migration_count applied migrations"

    # If backup provided, compare registry states
    if [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH/registry.json" ]]; then
        log_info "Comparing registry with backup..."

        local backup_count
        backup_count=$(jq '.appliedMigrations | length' "$BACKUP_PATH/registry.json" 2>/dev/null || echo "0")

        if [[ "$migration_count" == "$backup_count" ]]; then
            log_success "Registry migration count matches backup ($migration_count)"
        else
            log_error "Registry migration count mismatch (current: $migration_count, backup: $backup_count)"
        fi

        # Compare actual migration IDs
        local current_ids
        local backup_ids
        current_ids=$(jq -r '.appliedMigrations[].id' "$registry_file" 2>/dev/null | sort)
        backup_ids=$(jq -r '.appliedMigrations[].id' "$BACKUP_PATH/registry.json" 2>/dev/null | sort)

        if [[ "$current_ids" == "$backup_ids" ]]; then
            log_success "Registry migration IDs match backup"
        else
            log_error "Registry migration IDs differ from backup"
            log_verbose "Current: $current_ids"
            log_verbose "Backup: $backup_ids"
        fi
    else
        log_verbose "No registry backup available for comparison"
        # Note: The backup format may not yet include registry.json
        # If backup-side support is needed, the backup script should copy the registry file
    fi
}

# Check database schema checksum (lightweight sanity check)
# Note: This provides a basic schema verification without a full diff.
# For complete verification, a schema dump should be stored in the backup.
check_database_schema() {
    if [[ -z "$BACKUP_PATH" ]]; then
        log_skip "Database schema: no backup path provided for comparison"
        return
    fi

    log_info "Checking database schema..."

    # Check if backup contains schema checksum or dump
    if [[ -f "$BACKUP_PATH/schema_checksum.txt" ]]; then
        local backup_checksum
        backup_checksum=$(cat "$BACKUP_PATH/schema_checksum.txt" 2>/dev/null)

        # Get current schema checksum
        local current_checksum
        current_checksum=$(lxc exec infinibay-postgres -- su - postgres -c \
            "psql -t -c \"SELECT md5(string_agg(table_name || column_name || data_type, '' ORDER BY table_name, column_name)) FROM information_schema.columns WHERE table_schema = 'public'\" infinibay" 2>/dev/null | tr -d ' \n' || echo "error")

        if [[ "$current_checksum" == "$backup_checksum" ]]; then
            log_success "Database schema checksum matches backup"
        else
            log_error "Database schema checksum mismatch"
            log_verbose "Current: $current_checksum"
            log_verbose "Backup: $backup_checksum"
        fi
    elif [[ -f "$BACKUP_PATH/schema.sql" ]]; then
        # If a schema dump exists, we could compare (expensive operation)
        log_skip "Database schema: full dump comparison not implemented (would be slow)"
        log_verbose "Backup contains schema.sql but comparison is skipped for performance"
    else
        log_skip "Database schema: backup does not contain schema checksum or dump"
        # Note: To enable this check, the backup script should store schema info:
        # psql -c "SELECT md5(...)" > schema_checksum.txt
        # OR: pg_dump --schema-only > schema.sql
    fi
}

# Generate summary report
generate_summary() {
    echo ""
    echo "=============================================="
    echo "ROLLBACK VERIFICATION SUMMARY"
    echo "=============================================="
    echo "Expected Version: $EXPECTED_VERSION"
    if [[ -n "$BACKUP_PATH" ]]; then
        echo "Backup Path: $BACKUP_PATH"
    fi
    echo ""
    echo "Results:"
    echo "  Checks Passed:  $CHECKS_PASSED"
    echo "  Checks Failed:  $CHECKS_FAILED"
    echo "  Checks Skipped: $CHECKS_SKIPPED"
    echo "=============================================="

    if [[ $CHECKS_FAILED -gt 0 ]]; then
        echo -e "${RED}VERIFICATION FAILED${NC}"
        echo ""
        echo "Some checks failed. The system may not have been properly restored."
        echo "Review the failed checks above and consider manual intervention."
        return 1
    else
        echo -e "${GREEN}VERIFICATION PASSED${NC}"
        echo ""
        echo "System appears to be properly restored to expected state."
        return 0
    fi
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "  ROLLBACK VERIFICATION SCRIPT"
    echo "========================================"
    echo ""

    log_info "Starting verification..."
    log_verbose "Expected version: $EXPECTED_VERSION"
    log_verbose "Backup path: ${BACKUP_PATH:-'(none provided)'}"
    echo ""

    # Run all checks
    check_version
    echo ""

    check_services
    echo ""

    check_database
    echo ""

    check_backend_health
    echo ""

    check_frontend_health
    echo ""

    check_git_commits
    echo ""

    check_uncommitted_changes
    echo ""

    check_migration_registry
    echo ""

    check_database_schema
    echo ""

    # Generate summary
    if generate_summary; then
        exit 0
    else
        exit 1
    fi
}

# Run main
main "$@"

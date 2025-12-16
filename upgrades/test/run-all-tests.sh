#!/usr/bin/env bash

# run-all-tests.sh - Automated test runner for upgrade system
#
# Runs all test scenarios sequentially, verifying expected outcomes.
# Use this script to validate the upgrade system's error handling and rollback.
#
# Usage:
#   ./run-all-tests.sh              # Run all tests
#   ./run-all-tests.sh --verbose    # Run with verbose output
#   ./run-all-tests.sh test-success # Run specific test
#   ./run-all-tests.sh --ci         # Run in CI mode (no colors, machine-readable)
#   ./run-all-tests.sh --reset-full # Full environment reset between tests (slow)
#
# Environment Reset Modes:
#   Default: Resets version file and restores from baseline backup between tests.
#            This is fast but assumes the backup/rollback system works correctly.
#   --reset-full: Destroys and recreates containers between tests (slow but thorough).
#                 Use this for CI or when you need complete isolation.

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
BACKUP_DIR="/data/backups"
TEST_REPORT="$SCRIPT_DIR/test-report.txt"
BASE_VERSION="test-base"

# Flags
VERBOSE=false
CI_MODE=false
SINGLE_TEST=""
RESET_FULL=false
BASELINE_BACKUP=""

# Test results
declare -A TEST_RESULTS
TESTS_PASSED=0
TESTS_FAILED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --ci)
            CI_MODE=true
            RED=""
            GREEN=""
            YELLOW=""
            BLUE=""
            NC=""
            shift
            ;;
        --reset-full)
            RESET_FULL=true
            shift
            ;;
        test-*)
            SINGLE_TEST="$1"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [TEST_NAME]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v   Show detailed output"
            echo "  --ci            CI mode (no colors)"
            echo "  --reset-full    Full environment reset between tests (slow)"
            echo "  --help, -h      Show this help"
            echo ""
            echo "Test Names:"
            echo "  test-success       Happy path test"
            echo "  test-build-fail    Build failure with rollback"
            echo "  test-migration-fail Migration failure with rollback"
            echo "  test-preflight-fail Pre-flight check failure"
            echo "  test-health-fail   Health check failure with rollback"
            echo "  test-data-migrations-upgrade Data migrations integration test"
            exit 0
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
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_verbose() {
    if $VERBOSE; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check we're in the right directory
    if [[ ! -f "$LXD_DIR/run.sh" ]]; then
        log_error "Cannot find run.sh in $LXD_DIR"
        exit 1
    fi

    # Check LXD is available
    if ! command -v lxc &> /dev/null; then
        log_error "LXD (lxc command) not found"
        exit 1
    fi

    # Check containers are running
    for container in infinibay-postgres infinibay-redis infinibay-backend infinibay-frontend; do
        STATUS=$(lxc list "$container" --format=csv -c s 2>/dev/null || echo "MISSING")
        if [[ "$STATUS" != "RUNNING" ]]; then
            log_error "Container $container is not running (status: $STATUS)"
            log_info "Run './run.sh apply' to start containers"
            exit 1
        fi
    done

    # Check backup directory exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warning "Backup directory $BACKUP_DIR does not exist, creating..."
        sudo mkdir -p "$BACKUP_DIR"
    fi

    # Check disk space (need at least 2GB)
    AVAILABLE=$(df "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    REQUIRED=$((2 * 1024 * 1024))  # 2GB in KB
    if [[ "$AVAILABLE" -lt "$REQUIRED" ]]; then
        log_warning "Low disk space: $(numfmt --to=iec-i --suffix=B $((AVAILABLE * 1024)))"
    fi

    log_success "Prerequisites check passed"
}

# Create baseline backup for test isolation
create_baseline_backup() {
    log_info "Creating baseline backup for test isolation..."

    BASELINE_BACKUP="$BACKUP_DIR/test_baseline_$(date +%Y%m%d_%H%M%S)"

    # Use run.sh backup if available, otherwise create minimal backup
    if "$LXD_DIR/run.sh" backup create "$BASELINE_BACKUP" > /dev/null 2>&1; then
        log_success "Baseline backup created: $BASELINE_BACKUP"
    else
        # Fallback: create directory and store version
        mkdir -p "$BASELINE_BACKUP"
        echo "$BASE_VERSION" > "$BASELINE_BACKUP/version.txt"
        log_warning "Created minimal baseline backup (full backup not available)"
    fi
}

# Reset test environment (called before each test)
reset_environment() {
    log_info "Resetting test environment..."

    if $RESET_FULL; then
        # Full reset: destroy and recreate containers
        log_info "Performing full environment reset (this may take several minutes)..."

        log_verbose "Destroying containers..."
        "$LXD_DIR/run.sh" destroy > /dev/null 2>&1 || true

        log_verbose "Creating containers..."
        "$LXD_DIR/run.sh" apply > /dev/null 2>&1 || {
            log_error "Failed to create containers"
            return 1
        }

        log_verbose "Provisioning services..."
        "$LXD_DIR/run.sh" provision > /dev/null 2>&1 || {
            log_error "Failed to provision services"
            return 1
        }

        # Reset version file
        echo "$BASE_VERSION" > "$VERSION_FILE"

        log_success "Full environment reset completed"
    else
        # Standard reset: restore from baseline backup
        log_verbose "Performing standard environment reset..."

        # Reset version file first
        echo "$BASE_VERSION" > "$VERSION_FILE"

        # Attempt to restore from baseline backup if it exists
        if [[ -n "$BASELINE_BACKUP" && -d "$BASELINE_BACKUP" ]]; then
            log_verbose "Restoring from baseline backup: $BASELINE_BACKUP"

            # Use run.sh rollback if available
            if "$LXD_DIR/run.sh" rollback "$BASELINE_BACKUP" > /dev/null 2>&1; then
                log_verbose "Restored from baseline backup"
            else
                log_verbose "Rollback not available, relying on version reset only"
            fi
        fi

        # Clean up any test backups from previous runs to avoid disk space issues
        # (keep the baseline backup)
        for test_backup in "$BACKUP_DIR"/test-*; do
            if [[ -d "$test_backup" && "$test_backup" != "$BASELINE_BACKUP" ]]; then
                log_verbose "Cleaning up test backup: $test_backup"
                rm -rf "$test_backup" 2>/dev/null || true
            fi
        done

        # Wait for services to settle
        sleep 2

        log_verbose "Standard environment reset completed"
    fi

    log_verbose "Version reset to $BASE_VERSION"
}

# Cleanup baseline backup
cleanup_baseline() {
    if [[ -n "$BASELINE_BACKUP" && -d "$BASELINE_BACKUP" ]]; then
        log_verbose "Removing baseline backup: $BASELINE_BACKUP"
        rm -rf "$BASELINE_BACKUP" 2>/dev/null || true
    fi
}

# Count backups matching pattern
count_backups() {
    local pattern="$1"
    ls -1 "$BACKUP_DIR" 2>/dev/null | grep -c "$pattern" || echo "0"
}

# Get current version
get_version() {
    cat "$VERSION_FILE" 2>/dev/null || echo "unknown"
}

# Check if services are healthy
check_services_healthy() {
    for container in infinibay-postgres infinibay-redis infinibay-backend infinibay-frontend; do
        STATUS=$(lxc list "$container" --format=csv -c s 2>/dev/null || echo "MISSING")
        if [[ "$STATUS" != "RUNNING" ]]; then
            return 1
        fi
    done
    return 0
}

# Run a single test
run_test() {
    local test_name="$1"
    local expected_exit="$2"
    local expected_version="$3"
    local expect_backup="$4"

    log_info "=============================================="
    log_info "Running test: $test_name"
    log_info "=============================================="

    # Reset environment
    reset_environment

    # Count backups before
    local backups_before
    backups_before=$(count_backups "$test_name")

    # Run the upgrade
    local exit_code=0
    local output

    log_verbose "Executing: $LXD_DIR/run.sh upgrade $test_name"

    if $VERBOSE; then
        "$LXD_DIR/run.sh" upgrade "$test_name" 2>&1 || exit_code=$?
    else
        output=$("$LXD_DIR/run.sh" upgrade "$test_name" 2>&1) || exit_code=$?
    fi

    # Verify exit code
    local passed=true

    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        log_error "Exit code: expected $expected_exit, got $exit_code"
        passed=false
    else
        log_success "Exit code: $exit_code (expected $expected_exit)"
    fi

    # Verify version
    local actual_version
    actual_version=$(get_version)
    if [[ "$actual_version" != "$expected_version" ]]; then
        log_error "Version: expected '$expected_version', got '$actual_version'"
        passed=false
    else
        log_success "Version: $actual_version (expected $expected_version)"
    fi

    # Verify backup creation
    local backups_after
    backups_after=$(count_backups "$test_name")
    local backup_created=$((backups_after - backups_before))

    if [[ "$expect_backup" == "yes" && "$backup_created" -eq 0 ]]; then
        log_error "Backup: expected backup to be created, but none found"
        passed=false
    elif [[ "$expect_backup" == "no" && "$backup_created" -gt 0 ]]; then
        log_error "Backup: expected no backup, but $backup_created created"
        passed=false
    else
        log_success "Backup: creation as expected (expect=$expect_backup, created=$backup_created)"
    fi

    # Verify services are healthy
    if check_services_healthy; then
        log_success "Services: all containers running"
    else
        log_error "Services: some containers not running"
        passed=false
    fi

    # Record result
    if $passed; then
        TEST_RESULTS[$test_name]="PASS"
        ((TESTS_PASSED++))
        log_success "Test $test_name: PASSED"
    else
        TEST_RESULTS[$test_name]="FAIL"
        ((TESTS_FAILED++))
        log_error "Test $test_name: FAILED"
    fi

    echo ""
}

# Generate test report
generate_report() {
    local report_file="$TEST_REPORT"

    {
        echo "=============================================="
        echo "UPGRADE SYSTEM TEST REPORT"
        echo "Generated: $(date)"
        echo "=============================================="
        echo ""
        echo "SUMMARY"
        echo "  Tests Passed: $TESTS_PASSED"
        echo "  Tests Failed: $TESTS_FAILED"
        echo "  Total Tests:  $((TESTS_PASSED + TESTS_FAILED))"
        echo ""
        echo "RESULTS"
        for test_name in "${!TEST_RESULTS[@]}"; do
            echo "  $test_name: ${TEST_RESULTS[$test_name]}"
        done
        echo ""
        echo "=============================================="
    } | tee "$report_file"

    log_info "Report saved to: $report_file"
}

# Cleanup test artifacts
cleanup() {
    log_info "Cleaning up test artifacts..."

    # Reset version file
    echo "$BASE_VERSION" > "$VERSION_FILE"

    # Remove baseline backup
    cleanup_baseline

    # Remove test backups created during this run
    for test_backup in "$BACKUP_DIR"/test-*; do
        if [[ -d "$test_backup" ]]; then
            log_verbose "Removing test backup: $test_backup"
            rm -rf "$test_backup" 2>/dev/null || true
        fi
    done

    log_verbose "Cleanup completed"
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "  INFINIBAY UPGRADE SYSTEM TEST SUITE  "
    echo "========================================"
    echo ""

    # Show reset mode
    if $RESET_FULL; then
        log_warning "Running with --reset-full: Full environment reset between tests (slow)"
    else
        log_info "Running with standard reset: Baseline backup restore between tests"
        log_info "Use --reset-full for complete isolation (slower but more thorough)"
    fi
    echo ""

    # Check prerequisites
    check_prerequisites

    # Create baseline backup for standard reset mode
    if ! $RESET_FULL; then
        create_baseline_backup
    fi

    # Define tests and expected outcomes
    # Format: test_name expected_exit expected_version expect_backup
    declare -a TESTS=(
        "test-success 0 test-success yes"
        "test-build-fail 1 test-base yes"
        "test-migration-fail 1 test-base yes"
        "test-preflight-fail 1 test-base no"
        "test-health-fail 1 test-base yes"
        "test-data-migrations-upgrade 0 test-data-migrations-upgrade yes"
    )

    # Run tests
    if [[ -n "$SINGLE_TEST" ]]; then
        # Run single test
        for test_spec in "${TESTS[@]}"; do
            read -r name exit_code version backup <<< "$test_spec"
            if [[ "$name" == "$SINGLE_TEST" ]]; then
                run_test "$name" "$exit_code" "$version" "$backup"
                break
            fi
        done

        if [[ ${#TEST_RESULTS[@]} -eq 0 ]]; then
            log_error "Unknown test: $SINGLE_TEST"
            exit 1
        fi
    else
        # Run all tests
        for test_spec in "${TESTS[@]}"; do
            read -r name exit_code version backup <<< "$test_spec"
            run_test "$name" "$exit_code" "$version" "$backup"
        done
    fi

    # Generate report
    generate_report

    # Cleanup
    cleanup

    # Exit with appropriate code
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Some tests failed!"
        exit 1
    else
        log_success "All tests passed!"
        exit 0
    fi
}

# Run main
main "$@"

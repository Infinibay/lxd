#!/usr/bin/env bash

################################################################################
# Infinibay Rollback Library
################################################################################
#
# Purpose:
#   Provides functions to rollback Infinibay installation to a previous backup
#   state. Implements the reverse-order restoration procedure: frontend →
#   backend → database → libvirt-node, with full rebuilds to ensure clean state.
#
# Main Functions:
#   - rollback_to_backup(backup_path)     - Main orchestration function
#   - rollback_frontend(backup_path)      - Rollback frontend to backed-up commit
#   - rollback_backend(backup_path)       - Rollback backend code to backed-up commit
#   - rollback_database(backup_path)      - Restore database from SQL dump
#   - rollback_libvirt_node(backup_path)  - Rollback libvirt-node to backed-up commit
#   - verify_rollback(backup_path)        - Verify services are running after rollback
#
# Usage Example:
#   source lib/rollback.sh
#   rollback_to_backup "/var/lib/postgresql/infinibay_backups/backup_20250124_120000"
#
# Rollback Sequence:
#   1. Validate backup exists and contains required files
#   2. Stop infinibay-frontend and infinibay-backend services
#   3. Rollback frontend: git reset, clean build artifacts, rebuild
#   4. Rollback backend: git reset, clean build artifacts, reinstall deps
#   5. Rollback database: drop, recreate, restore from SQL dump
#   6. Rebuild backend with old schema: prisma generate, rebuild TypeScript
#   7. Rollback libvirt-node: git reset, rebuild Rust module, repackage
#   8. Start infinibay-backend and infinibay-frontend services
#   9. Verify services are active and responding
#
# Dependencies:
#   - LXD containers: infinibay-frontend, infinibay-backend, infinibay-postgres
#   - Backup created by backup.sh with commit hashes and SQL dump
#
################################################################################

# Color definitions for output
# Only define if not already set (to avoid conflicts when sourced from scripts that define them)
[[ -z "${GREEN:-}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${YELLOW:-}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${RED:-}" ]] && readonly RED='\033[0;31m'
[[ -z "${BLUE:-}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${NC:-}" ]] && readonly NC='\033[0m' # No Color

################################################################################
# check_backup_exists
#
# Validates that the backup directory exists and contains all required files.
#
# Arguments:
#   $1 - backup_path: Path to backup directory in postgres container
#
# Returns:
#   0 if backup is valid
#   1 if backup is invalid or missing required files
#
# Required files:
#   - infinibay_backup.sql (database dump)
#   - backend_commit.txt (backend git state)
#   - frontend_commit.txt (frontend git state)
#
# Optional files:
#   - libvirt-node_commit.txt (libvirt-node git state, rollback skipped if missing)
#   - lxd_commit.txt (lxd git state, informational only)
#
# Note: Backups without libvirt-node_commit.txt can still be used for rollback.
#       The rollback_libvirt_node() function will skip the rollback with a warning
#       if this file is missing or contains "unknown".
################################################################################
check_backup_exists() {
    local backup_path="$1"

    echo -e "${BLUE}Checking backup at: $backup_path${NC}"

    # Check if backup directory exists
    if ! lxc exec infinibay-postgres -- test -d "$backup_path"; then
        echo -e "${RED}Error: Backup directory does not exist: $backup_path${NC}"
        return 1
    fi

    # Check for required files (backend and frontend are critical for rollback)
    local required_files=(
        "infinibay_backup.sql"
        "backend_commit.txt"
        "frontend_commit.txt"
    )

    for file in "${required_files[@]}"; do
        if ! lxc exec infinibay-postgres -- test -f "$backup_path/$file"; then
            echo -e "${RED}Error: Required backup file missing: $file${NC}"
            return 1
        fi
    done

    # Check for optional libvirt-node commit (non-critical)
    if ! lxc exec infinibay-postgres -- test -f "$backup_path/libvirt-node_commit.txt"; then
        echo -e "${YELLOW}⚠ Warning: libvirt-node_commit.txt is missing (optional)${NC}"
        echo -e "${YELLOW}  Libvirt-node rollback will be skipped${NC}"
    fi

    echo -e "${GREEN}✓ Backup validation passed${NC}"
    return 0
}

################################################################################
# stop_services
#
# Stops the infinibay-frontend and infinibay-backend systemd services.
#
# Returns:
#   0 on success
#   1 on failure
################################################################################
stop_services() {
    echo -e "${BLUE}Stopping Infinibay services...${NC}"

    # Stop frontend service
    echo -e "${BLUE}  Stopping infinibay-frontend...${NC}"
    local frontend_stop_result=0
    lxc exec infinibay-frontend -- systemctl stop infinibay-frontend || frontend_stop_result=$?

    if [ $frontend_stop_result -ne 0 ]; then
        echo -e "${YELLOW}  Warning: Failed to stop infinibay-frontend (may not be running)${NC}"
    fi

    # Stop backend service
    echo -e "${BLUE}  Stopping infinibay-backend...${NC}"
    local backend_stop_result=0
    lxc exec infinibay-backend -- systemctl stop infinibay-backend || backend_stop_result=$?

    if [ $backend_stop_result -ne 0 ]; then
        echo -e "${YELLOW}  Warning: Failed to stop infinibay-backend (may not be running)${NC}"
    fi

    echo -e "${GREEN}✓ Services stopped${NC}"
    return 0
}

################################################################################
# start_services
#
# Starts the infinibay-backend and infinibay-frontend systemd services.
# Starts backend first, waits 3 seconds, then starts frontend.
#
# Returns:
#   0 on success
#   1 if services fail to start
################################################################################
start_services() {
    echo -e "${BLUE}Starting Infinibay services...${NC}"

    # Start backend service first
    echo -e "${BLUE}  Starting infinibay-backend...${NC}"
    lxc exec infinibay-backend -- systemctl start infinibay-backend

    # Wait for backend to initialize
    sleep 3

    # Check backend status
    local backend_status=0
    lxc exec infinibay-backend -- systemctl is-active --quiet infinibay-backend || backend_status=$?

    if [ $backend_status -ne 0 ]; then
        echo -e "${RED}Error: infinibay-backend failed to start${NC}"
        echo -e "${RED}Check logs: lxc exec infinibay-backend -- journalctl -u infinibay-backend -n 50${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ infinibay-backend started${NC}"

    # Start frontend service
    echo -e "${BLUE}  Starting infinibay-frontend...${NC}"
    lxc exec infinibay-frontend -- systemctl start infinibay-frontend

    # Wait for frontend to initialize
    sleep 3

    # Check frontend status
    local frontend_status=0
    lxc exec infinibay-frontend -- systemctl is-active --quiet infinibay-frontend || frontend_status=$?

    if [ $frontend_status -ne 0 ]; then
        echo -e "${RED}Error: infinibay-frontend failed to start${NC}"
        echo -e "${RED}Check logs: lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -n 50${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ infinibay-frontend started${NC}"
    echo -e "${GREEN}✓ All services started successfully${NC}"
    return 0
}

################################################################################
# rollback_frontend
#
# Rolls back the frontend to the commit hash stored in the backup.
# Performs: git reset, clean build artifacts, reinstall deps, rebuild.
#
# Arguments:
#   $1 - backup_path: Path to backup directory in postgres container
#
# Returns:
#   0 on success
#   1 on failure
################################################################################
rollback_frontend() {
    local backup_path="$1"

    echo -e "${BLUE}Rolling back frontend...${NC}"

    # Read commit hash from backup
    local commit_hash
    commit_hash=$(lxc exec infinibay-postgres -- cat "$backup_path/frontend_commit.txt")

    if [ -z "$commit_hash" ]; then
        echo -e "${RED}Error: Could not read frontend commit hash from backup${NC}"
        return 1
    fi

    # Check for unknown commit marker
    if [ "$commit_hash" = "unknown" ]; then
        echo -e "${RED}Error: Frontend backup contains 'unknown' commit hash${NC}"
        echo -e "${RED}This backup does not contain valid frontend commit information${NC}"
        echo -e "${RED}The backup cannot be used for code rollback${NC}"
        return 1
    fi

    echo -e "${BLUE}  Target commit: $commit_hash${NC}"

    # Reset git repository to backed-up commit
    echo -e "${BLUE}  Resetting git repository...${NC}"
    lxc exec infinibay-frontend -- git -C /opt/infinibay/frontend reset --hard "$commit_hash"

    # Remove build artifacts
    echo -e "${BLUE}  Removing build artifacts...${NC}"
    lxc exec infinibay-frontend -- rm -rf /opt/infinibay/frontend/node_modules
    lxc exec infinibay-frontend -- rm -rf /opt/infinibay/frontend/.next

    # Reinstall dependencies as infinibay user
    echo -e "${BLUE}  Reinstalling dependencies...${NC}"
    local install_result=0
    lxc exec infinibay-frontend -- su - infinibay -c "cd /opt/infinibay/frontend && HUSKY=0 npm install" || install_result=$?

    if [ $install_result -ne 0 ]; then
        echo -e "${RED}Error: Failed to install frontend dependencies${NC}"
        return 1
    fi

    # Rebuild frontend
    echo -e "${BLUE}  Building frontend...${NC}"
    local build_result=0
    lxc exec infinibay-frontend -- su - infinibay -c "cd /opt/infinibay/frontend && npm run build" || build_result=$?

    if [ $build_result -ne 0 ]; then
        echo -e "${RED}Error: Failed to build frontend${NC}"
        return 1
    fi

    # Verify .next directory exists
    if ! lxc exec infinibay-frontend -- test -d /opt/infinibay/frontend/.next; then
        echo -e "${RED}Error: Frontend build did not create .next directory${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Frontend rolled back to $commit_hash${NC}"
    return 0
}

################################################################################
# rollback_backend
#
# Rolls back the backend code to the commit hash stored in the backup.
# Performs: git reset, clean build artifacts, reinstall deps.
# Note: Database restore and Prisma generation happen in separate functions.
#
# Arguments:
#   $1 - backup_path: Path to backup directory in postgres container
#
# Returns:
#   0 on success
#   1 on failure
################################################################################
rollback_backend() {
    local backup_path="$1"

    echo -e "${BLUE}Rolling back backend code...${NC}"

    # Read commit hash from backup
    local commit_hash
    commit_hash=$(lxc exec infinibay-postgres -- cat "$backup_path/backend_commit.txt")

    if [ -z "$commit_hash" ]; then
        echo -e "${RED}Error: Could not read backend commit hash from backup${NC}"
        return 1
    fi

    # Check for unknown commit marker
    if [ "$commit_hash" = "unknown" ]; then
        echo -e "${RED}Error: Backend backup contains 'unknown' commit hash${NC}"
        echo -e "${RED}This backup does not contain valid backend commit information${NC}"
        echo -e "${RED}The backup cannot be used for code rollback${NC}"
        return 1
    fi

    echo -e "${BLUE}  Target commit: $commit_hash${NC}"

    # Reset git repository to backed-up commit
    echo -e "${BLUE}  Resetting git repository...${NC}"
    lxc exec infinibay-backend -- git -C /opt/infinibay/backend reset --hard "$commit_hash"

    # Remove build artifacts
    echo -e "${BLUE}  Removing build artifacts...${NC}"
    lxc exec infinibay-backend -- rm -rf /opt/infinibay/backend/node_modules
    lxc exec infinibay-backend -- rm -rf /opt/infinibay/backend/dist
    lxc exec infinibay-backend -- rm -f /opt/infinibay/backend/package-lock.json

    # Reinstall dependencies as infinibay user
    echo -e "${BLUE}  Reinstalling dependencies...${NC}"
    local install_result=0
    lxc exec infinibay-backend -- su - infinibay -c "cd /opt/infinibay/backend && npm install" || install_result=$?

    if [ $install_result -ne 0 ]; then
        echo -e "${RED}Error: Failed to install backend dependencies${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Backend code rolled back to $commit_hash${NC}"
    return 0
}

################################################################################
# rollback_database
#
# Restores the database from the SQL dump in the backup.
# Performs: drop existing database, create fresh database, restore from backup.
#
# Arguments:
#   $1 - backup_path: Path to backup directory inside infinibay-postgres container
#                     (e.g., /data/backups/backup_20250124_120000)
#
# Returns:
#   0 on success
#   1 on failure
################################################################################
rollback_database() {
    local backup_path="$1"

    echo -e "${BLUE}Rolling back database...${NC}"

    # Verify SQL dump exists in the container before proceeding
    echo -e "${BLUE}  Verifying SQL backup exists...${NC}"
    if ! lxc exec infinibay-postgres -- test -f "$backup_path/infinibay_backup.sql"; then
        echo -e "${RED}Error: SQL backup file not found at $backup_path/infinibay_backup.sql${NC}"
        echo -e "${RED}Note: backup_path must be a path inside the infinibay-postgres container${NC}"
        return 1
    fi

    # Source backend .env to get DB_NAME (default to 'infinibay')
    local db_name="infinibay"
    local env_db_name
    local rc=0
    env_db_name=$(lxc exec infinibay-backend -- bash -c "source /opt/infinibay/backend/.env 2>/dev/null && echo \$DB_NAME") || rc=$?

    if [ -n "$env_db_name" ]; then
        db_name="$env_db_name"
    fi

    echo -e "${BLUE}  Database: $db_name${NC}"

    # Copy SQL backup to temporary location within postgres container
    echo -e "${BLUE}  Copying SQL backup to restore location...${NC}"
    rc=0
    lxc exec infinibay-postgres -- cp "$backup_path/infinibay_backup.sql" /tmp/restore.sql || rc=$?

    if [ $rc -ne 0 ]; then
        echo -e "${RED}Error: Failed to copy SQL backup within postgres container${NC}"
        return 1
    fi

    # Drop existing database
    echo -e "${BLUE}  Dropping existing database...${NC}"
    rc=0
    lxc exec infinibay-postgres -- su - postgres -c "dropdb $db_name" || rc=$?

    if [ $rc -ne 0 ]; then
        echo -e "${RED}Error: Failed to drop database $db_name${NC}"
        return 1
    fi

    # Create fresh database
    echo -e "${BLUE}  Creating fresh database...${NC}"
    rc=0
    lxc exec infinibay-postgres -- su - postgres -c "createdb $db_name" || rc=$?

    if [ $rc -ne 0 ]; then
        echo -e "${RED}Error: Failed to create database $db_name${NC}"
        return 1
    fi

    # Restore from backup
    echo -e "${BLUE}  Restoring from SQL backup...${NC}"
    rc=0
    lxc exec infinibay-postgres -- su - postgres -c "psql $db_name < /tmp/restore.sql" || rc=$?

    if [ $rc -ne 0 ]; then
        echo -e "${RED}Error: Failed to restore database from backup${NC}"
        echo -e "${RED}Database is in an inconsistent state!${NC}"
        return 1
    fi

    # Clean up temporary file
    lxc exec infinibay-postgres -- rm -f /tmp/restore.sql

    echo -e "${GREEN}✓ Database restored from backup${NC}"
    return 0
}

################################################################################
# rebuild_backend_with_old_schema
#
# Rebuilds the backend with the old Prisma schema after database restoration.
# Performs: prisma generate, remove dist, rebuild TypeScript.
#
# Arguments:
#   $1 - backup_path: Path to backup directory (unused but kept for consistency)
#
# Returns:
#   0 on success
#   1 on failure
################################################################################
rebuild_backend_with_old_schema() {
    local backup_path="$1"

    echo -e "${BLUE}Rebuilding backend with old schema...${NC}"

    # Generate Prisma client with old schema
    echo -e "${BLUE}  Generating Prisma client...${NC}"
    local prisma_result=0
    lxc exec infinibay-backend -- bash -c "cd /opt/infinibay/backend && npx prisma generate" || prisma_result=$?

    if [ $prisma_result -ne 0 ]; then
        echo -e "${RED}Error: Failed to generate Prisma client${NC}"
        return 1
    fi

    # Remove dist directory
    echo -e "${BLUE}  Removing dist directory...${NC}"
    lxc exec infinibay-backend -- rm -rf /opt/infinibay/backend/dist

    # Build TypeScript as infinibay user
    echo -e "${BLUE}  Building TypeScript...${NC}"
    local build_result=0
    lxc exec infinibay-backend -- su - infinibay -c "cd /opt/infinibay/backend && npm run build" || build_result=$?

    if [ $build_result -ne 0 ]; then
        echo -e "${RED}Error: Failed to build backend${NC}"
        return 1
    fi

    # Verify dist/index.js exists
    if ! lxc exec infinibay-backend -- test -f /opt/infinibay/backend/dist/index.js; then
        echo -e "${RED}Error: Backend build did not create dist/index.js${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Backend rebuilt with old schema${NC}"
    return 0
}

################################################################################
# rollback_libvirt_node
#
# Rolls back the libvirt-node to the commit hash stored in the backup.
# Performs: git reset, rebuild Rust module, repackage.
# Non-critical: logs warning if rebuild fails (backend may use cached version).
#
# Arguments:
#   $1 - backup_path: Path to backup directory in postgres container
#
# Returns:
#   0 on success or non-critical failure
#   1 only on critical errors
################################################################################
rollback_libvirt_node() {
    local backup_path="$1"

    echo -e "${BLUE}Rolling back libvirt-node...${NC}"

    # Check if libvirt-node commit file exists
    if ! lxc exec infinibay-postgres -- test -f "$backup_path/libvirt-node_commit.txt"; then
        echo -e "${YELLOW}Warning: libvirt-node_commit.txt not found in backup${NC}"
        echo -e "${YELLOW}Skipping libvirt-node rollback (non-critical)${NC}"
        return 0  # Non-critical
    fi

    # Read commit hash from backup
    local target_commit
    target_commit=$(lxc exec infinibay-postgres -- cat "$backup_path/libvirt-node_commit.txt")

    if [ -z "$target_commit" ]; then
        echo -e "${YELLOW}Warning: Could not read libvirt-node commit hash from backup${NC}"
        echo -e "${YELLOW}Skipping libvirt-node rollback (non-critical)${NC}"
        return 0  # Non-critical
    fi

    # Check for unknown commit marker
    if [ "$target_commit" = "unknown" ]; then
        echo -e "${YELLOW}Warning: libvirt-node backup contains 'unknown' commit hash${NC}"
        echo -e "${YELLOW}Skipping libvirt-node rollback (non-critical)${NC}"
        return 0  # Non-critical
    fi

    echo -e "${BLUE}  Target commit: $target_commit${NC}"

    # Get current commit
    local current_commit
    current_commit=$(lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node rev-parse HEAD)

    # Compare commits
    if [ "$current_commit" = "$target_commit" ]; then
        echo -e "${GREEN}✓ libvirt-node already at target commit, skipping rebuild${NC}"
        return 0
    fi

    # Reset to backup commit
    echo -e "${BLUE}  Resetting git repository...${NC}"
    lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node reset --hard "$target_commit"

    # Remove build artifacts
    echo -e "${BLUE}  Removing build artifacts...${NC}"
    lxc exec infinibay-backend -- rm -rf /opt/infinibay/libvirt-node/node_modules
    lxc exec infinibay-backend -- rm -rf /opt/infinibay/libvirt-node/target

    # Reinstall dependencies and rebuild
    echo -e "${BLUE}  Rebuilding libvirt-node (this may take a few minutes)...${NC}"
    local build_result=0
    lxc exec infinibay-backend -- su - infinibay -c "cd /opt/infinibay/libvirt-node && npm install && source ~/.cargo/env && npm run build" || build_result=$?

    if [ $build_result -ne 0 ]; then
        echo -e "${YELLOW}Warning: Failed to rebuild libvirt-node${NC}"
        echo -e "${YELLOW}Backend may use cached version. Check logs if VM operations fail.${NC}"
        return 0  # Non-critical failure
    fi

    # Package the module
    echo -e "${BLUE}  Packaging libvirt-node...${NC}"
    local pack_result=0
    lxc exec infinibay-backend -- su - infinibay -c "cd /opt/infinibay/libvirt-node && npm pack" || pack_result=$?

    if [ $pack_result -ne 0 ]; then
        echo -e "${YELLOW}Warning: Failed to package libvirt-node${NC}"
        return 0  # Non-critical failure
    fi

    # Copy tarball to backend lib directory
    echo -e "${BLUE}  Copying package to backend...${NC}"
    lxc exec infinibay-backend -- bash -c "mkdir -p /opt/infinibay/backend/lib/libvirt-node && cp /opt/infinibay/libvirt-node/infinibay-libvirt-node-*.tgz /opt/infinibay/backend/lib/libvirt-node/"

    echo -e "${GREEN}✓ libvirt-node rolled back to $target_commit${NC}"
    return 0
}

################################################################################
# verify_rollback
#
# Verifies that the rollback was successful by checking service status.
# Displays summary with commit hashes and database restore timestamp.
#
# Arguments:
#   $1 - backup_path: Path to backup directory in postgres container
#
# Returns:
#   0 if services are running
#   1 if any service is down
################################################################################
verify_rollback() {
    local backup_path="$1"

    echo -e "${BLUE}Verifying rollback...${NC}"

    # Check backend service
    local backend_status=0
    lxc exec infinibay-backend -- systemctl is-active --quiet infinibay-backend || backend_status=$?

    if [ $backend_status -ne 0 ]; then
        echo -e "${RED}Error: infinibay-backend is not running${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ infinibay-backend is active${NC}"

    # Check frontend service
    local frontend_status=0
    lxc exec infinibay-frontend -- systemctl is-active --quiet infinibay-frontend || frontend_status=$?

    if [ $frontend_status -ne 0 ]; then
        echo -e "${RED}Error: infinibay-frontend is not running${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ infinibay-frontend is active${NC}"

    # Display rollback summary
    echo -e "${BLUE}Rollback summary:${NC}"

    local frontend_commit
    frontend_commit=$(lxc exec infinibay-postgres -- cat "$backup_path/frontend_commit.txt")
    echo -e "${BLUE}  Frontend commit: $frontend_commit${NC}"

    local backend_commit
    backend_commit=$(lxc exec infinibay-postgres -- cat "$backup_path/backend_commit.txt")
    echo -e "${BLUE}  Backend commit: $backend_commit${NC}"

    local libvirt_commit
    libvirt_commit=$(lxc exec infinibay-postgres -- cat "$backup_path/libvirt-node_commit.txt")
    echo -e "${BLUE}  Libvirt-node commit: $libvirt_commit${NC}"

    # Get backup timestamp from backup directory name or file
    local backup_timestamp
    backup_timestamp=$(basename "$backup_path" | sed 's/backup_//')
    echo -e "${BLUE}  Database restored from: $backup_timestamp${NC}"

    # TODO: Add health checks
    # - curl backend GraphQL endpoint
    # - curl frontend homepage
    # - check for critical errors in logs

    echo -e "${GREEN}✓ Rollback verification passed${NC}"
    return 0
}

################################################################################
# rollback_to_backup
#
# Main orchestration function that performs complete rollback to a backup.
# Executes the full rollback sequence with comprehensive error handling.
#
# Arguments:
#   $1 - backup_path: Path to backup directory in postgres container
#                     Example: /var/lib/postgresql/infinibay_backups/backup_20250124_120000
#
# Returns:
#   0 on complete success
#   1 on any critical failure
#
# Rollback sequence:
#   1. Validate backup
#   2. Stop services
#   3. Rollback frontend (critical)
#   4. Rollback backend code (critical)
#   5. Rollback database (critical)
#   6. Rebuild backend with old schema (critical)
#   7. Rollback libvirt-node (non-critical)
#   8. Start services
#   9. Verify services are active
################################################################################
rollback_to_backup() {
    local backup_path="$1"

    # Validate backup_path argument
    if [ -z "$backup_path" ]; then
        echo -e "${RED}Error: backup_path argument is required${NC}"
        echo -e "Usage: rollback_to_backup <backup_path>"
        echo -e "Example: rollback_to_backup /var/lib/postgresql/infinibay_backups/backup_20250124_120000"
        return 1
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          Infinibay Rollback to Previous State${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}WARNING: This will restore Infinibay to a previous backup state.${NC}"
    echo -e "${YELLOW}All changes made since the backup will be lost.${NC}"
    echo -e "${BLUE}Backup: $backup_path${NC}"
    echo ""

    # Validate backup exists
    if ! check_backup_exists "$backup_path"; then
        return 1
    fi

    echo ""

    # Stop services
    if ! stop_services; then
        echo -e "${RED}Failed to stop services. Aborting rollback.${NC}"
        return 1
    fi

    echo ""

    # Execute rollback sequence
    # Frontend (critical)
    if ! rollback_frontend "$backup_path"; then
        echo -e "${RED}CRITICAL: Frontend rollback failed. System in inconsistent state.${NC}"
        return 1
    fi

    echo ""

    # Backend code (critical)
    if ! rollback_backend "$backup_path"; then
        echo -e "${RED}CRITICAL: Backend rollback failed. System in inconsistent state.${NC}"
        return 1
    fi

    echo ""

    # Database (critical)
    if ! rollback_database "$backup_path"; then
        echo -e "${RED}CRITICAL: Database rollback failed. System in inconsistent state.${NC}"
        return 1
    fi

    echo ""

    # Rebuild backend with old schema (critical)
    if ! rebuild_backend_with_old_schema "$backup_path"; then
        echo -e "${RED}CRITICAL: Backend rebuild failed. System in inconsistent state.${NC}"
        return 1
    fi

    echo ""

    # Libvirt-node (non-critical)
    rollback_libvirt_node "$backup_path"
    # Note: Returns 0 even on failure (non-critical)

    echo ""

    # Start services
    if ! start_services; then
        echo -e "${RED}CRITICAL: Failed to start services after rollback.${NC}"
        echo -e "${RED}Manual intervention required.${NC}"
        return 1
    fi

    echo ""

    # Verify rollback
    if ! verify_rollback "$backup_path"; then
        echo -e "${RED}CRITICAL: Rollback verification failed.${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}          Rollback Completed Successfully${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Infinibay has been restored to the backup state.${NC}"
    echo -e "${BLUE}Services are running and ready to accept requests.${NC}"
    echo ""

    return 0
}

#!/usr/bin/env bash

# pre-flight.sh - Pre-flight checks for test-data-migrations-upgrade
#
# This script performs basic checks to ensure the system is ready for upgrade.

set -e

echo "Running pre-flight checks for test-data-migrations-upgrade..."

# Check 1: Verify disk space (need at least 1GB for test backup)
echo "Checking disk space..."
AVAILABLE_SPACE=$(df /data/backups 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
REQUIRED_SPACE=$((1 * 1024 * 1024))  # 1GB in KB

if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    echo "ERROR: Insufficient disk space for backup"
    echo "Available: $(numfmt --to=iec-i --suffix=B $((AVAILABLE_SPACE * 1024)) 2>/dev/null || echo "${AVAILABLE_SPACE}KB")"
    echo "Required: 1GB"
    exit 1
fi

echo "  Disk space check passed"

# Check 2: Verify all containers are running
echo "Checking container status..."
for container in infinibay-postgres infinibay-backend infinibay-frontend; do
    STATUS=$(lxc list "$container" --format=csv -c s 2>/dev/null || echo "MISSING")
    if [ "$STATUS" != "RUNNING" ]; then
        echo "ERROR: Container $container is not running (status: $STATUS)"
        echo "Hint: Start containers with './run.sh apply'"
        exit 1
    fi
    echo "  $container is running"
done

# Check 3: Verify database is accessible
echo "Checking database connectivity..."
if ! lxc exec infinibay-postgres -- su - postgres -c "psql -c 'SELECT 1' infinibay" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to PostgreSQL database"
    echo "Hint: Check PostgreSQL logs with './run.sh logs postgres'"
    exit 1
fi
echo "  Database connectivity check passed"

echo ""
echo "All pre-flight checks passed!"
exit 0

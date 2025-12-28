#!/usr/bin/env bash

# validate-health.sh - Post-upgrade health checks
#
# This script verifies the system is healthy after the upgrade.

set -e

echo "Running post-upgrade health checks..."

# Check containers are running
echo "Checking container status..."
for container in infinibay-postgres infinibay-backend infinibay-frontend; do
    STATUS=$(lxc list "$container" --format=csv -c s 2>/dev/null || echo "MISSING")
    if [ "$STATUS" != "RUNNING" ]; then
        echo "ERROR: Container $container is not running (status: $STATUS)"
        exit 1
    fi
    echo "  $container is running"
done

# Check database connection
echo "Checking database connection..."
if lxc exec infinibay-postgres -- su - postgres -c "psql -c 'SELECT 1' infinibay" > /dev/null 2>&1; then
    echo "  Database connection successful"
else
    echo "ERROR: Database connection failed"
    exit 1
fi

echo ""
echo "=========================================="
echo "Health checks passed!"
echo "=========================================="

exit 0

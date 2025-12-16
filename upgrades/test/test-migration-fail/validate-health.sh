#!/usr/bin/env bash

# validate-health.sh - Stub script for test-migration-fail scenario
#
# This script should NOT be reached during the test-migration-fail scenario
# because the data migration step fails and triggers rollback before
# validation runs. It exists to prevent "script not found" errors.

set -e

echo "=========================================="
echo "WARNING: This script should not have been reached!"
echo "The data migration step should have failed and triggered rollback."
echo "=========================================="

echo ""
echo "Running health checks (stub)..."
sleep 1
echo "Health checks passed (stub)."

exit 0

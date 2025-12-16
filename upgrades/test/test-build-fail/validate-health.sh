#!/usr/bin/env bash

# validate-health.sh - Stub script for test-build-fail scenario
#
# This script should NOT be reached during the test-build-fail scenario
# because the backend update step fails and triggers rollback before
# validation runs. It exists to prevent "script not found" errors.

set -e

echo "=========================================="
echo "WARNING: This script should not have been reached!"
echo "The backend update step should have failed and triggered rollback."
echo "=========================================="

echo ""
echo "Running health checks (stub)..."
sleep 1
echo "Health checks passed (stub)."

exit 0

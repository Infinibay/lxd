#!/usr/bin/env bash

# validate-health.sh - Stub script for test-preflight-fail scenario
#
# This script should NOT be reached during the test-preflight-fail scenario
# because the pre-flight check fails and blocks the upgrade before any
# steps or validation runs. It exists to prevent "script not found" errors.

set -e

echo "=========================================="
echo "WARNING: This script should not have been reached!"
echo "The pre-flight check should have failed and blocked the upgrade."
echo "=========================================="

echo ""
echo "Running health checks (stub)..."
sleep 1
echo "Health checks passed (stub)."

exit 0

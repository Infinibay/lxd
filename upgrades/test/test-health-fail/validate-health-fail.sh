#!/usr/bin/env bash

# validate-health-fail.sh - Health check that fails
#
# This script simulates a backend health check failure after upgrade.
# Used to test automatic rollback when validation fails.

echo "Running post-upgrade health checks..."

echo ""
echo "Checking backend service status..."
sleep 1
echo "  Backend service is active"

echo ""
echo "Checking backend API health endpoint..."
sleep 1

# Simulate health check failure
echo "" >&2
echo "=========================================="
echo "ERROR: Backend health check failed" >&2
echo "=========================================="
echo "" >&2
echo "Details:" >&2
echo "  Endpoint: http://localhost:4000/health" >&2
echo "  Expected: HTTP 200 OK" >&2
echo "  Received: HTTP 500 Internal Server Error" >&2
echo "" >&2
echo "Response body:" >&2
echo "  {" >&2
echo "    \"status\": \"error\"," >&2
echo "    \"message\": \"Database connection pool exhausted\"," >&2
echo "    \"timestamp\": \"$(date -Iseconds)\"" >&2
echo "  }" >&2
echo "" >&2
echo "The backend service is running but not responding correctly." >&2
echo "This may indicate a configuration issue or database problem." >&2
echo "" >&2
echo "Hint: Check backend logs with './run.sh logs backend'" >&2
echo "Hint: Verify database connection with './run.sh db status'" >&2
echo "" >&2

exit 1

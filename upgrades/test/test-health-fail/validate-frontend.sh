#!/usr/bin/env bash

# validate-frontend.sh - Stub script for test-health-fail scenario
#
# This script may or may not be reached during the test-health-fail scenario
# depending on whether the backend health check (which fails) short-circuits
# further validations. It exists to prevent "script not found" errors and
# performs a benign check if executed.

set -e

echo "Running frontend health check..."

# Benign check - just verify the frontend container is running
STATUS=$(lxc list "infinibay-frontend" --format=csv -c s 2>/dev/null || echo "MISSING")

if [[ "$STATUS" == "RUNNING" ]]; then
    echo "  Frontend container is running"
else
    echo "WARNING: Frontend container status: $STATUS"
fi

echo "Frontend health check completed."

exit 0

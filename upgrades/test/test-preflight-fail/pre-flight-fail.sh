#!/usr/bin/env bash

# pre-flight-fail.sh - Pre-flight check that fails
#
# This script simulates a pre-flight check failure (insufficient disk space).
# Used to test that upgrades are blocked when required checks fail.

echo "Running pre-flight checks for test-preflight-fail upgrade..."

# Check 1: Verify disk space - THIS WILL FAIL
echo "Checking disk space..."
sleep 1

# Simulate insufficient disk space
echo "" >&2
echo "=========================================="
echo "ERROR: Insufficient disk space for upgrade" >&2
echo "=========================================="
echo "" >&2
echo "Details:" >&2
echo "  Location: /data/backups" >&2
echo "  Available: 500MB" >&2
echo "  Required: 2GB minimum" >&2
echo "" >&2
echo "The upgrade cannot proceed without sufficient disk space" >&2
echo "for creating a backup of your current system." >&2
echo "" >&2
echo "Hint: Free up disk space before upgrading:" >&2
echo "  - Remove old backups: rm -rf /data/backups/old_*" >&2
echo "  - Clean up unused VMs: ./run.sh vm cleanup" >&2
echo "  - Check disk usage: df -h /data/backups" >&2
echo "" >&2

exit 1

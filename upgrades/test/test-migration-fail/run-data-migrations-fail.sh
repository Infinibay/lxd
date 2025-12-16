#!/usr/bin/env bash

# run-data-migrations-fail.sh - Simulates a data migration failure
#
# This script simulates a data migration that fails during execution.
# Used to test database rollback from backup.

echo "=========================================="
echo "Running data migrations..."
echo "=========================================="

echo ""
echo "Step 1: Loading migration registry..."
sleep 1
echo "  Registry loaded: 0 previously applied migrations"

echo ""
echo "Step 2: Scanning for pending migrations..."
sleep 1
echo "  Found 1 unapplied migration: 001_populate_test_field"

echo ""
echo "Step 3: Executing 001_populate_test_field..."
sleep 1
echo "  Starting migration: Populate testField for existing VMs"
echo "  Processing batch 1 of 1..."
sleep 1

# Simulate constraint violation error
echo "" >&2
echo "ERROR: Migration failed during execution" >&2
echo "" >&2
echo "PostgresError: duplicate key value violates unique constraint \"VM_testField_key\"" >&2
echo "  Detail: Key (\"testField\")=(default-value) already exists." >&2
echo "  Hint: Ensure unique values when populating testField column." >&2
echo "" >&2
echo "Transaction rolled back." >&2
echo "" >&2
echo "=========================================="
echo "ERROR: Data migration failed - constraint violation" >&2
echo "=========================================="

exit 1

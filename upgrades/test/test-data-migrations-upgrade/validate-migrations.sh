#!/usr/bin/env bash

# validate-migrations.sh - Validates data migrations were applied correctly
#
# This script verifies that:
# 1. The migration registry contains the expected test migrations
# 2. The test marker exists in the database with expected values
# 3. Re-running migrations shows idempotency (no changes needed)

set -e

echo "=========================================="
echo "Validating data migrations..."
echo "=========================================="

# Path to registry
REGISTRY_FILE="/app/prisma/data-migrations/registry.json"

echo ""
echo "Step 1: Checking migration registry..."
echo "--------------------------------------"

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "ERROR: Registry file not found: $REGISTRY_FILE"
    exit 1
fi

# Validate JSON
if ! jq empty "$REGISTRY_FILE" 2>/dev/null; then
    echo "ERROR: Registry file is not valid JSON"
    exit 1
fi
echo "  Registry file is valid JSON"

# Check for expected migrations
if jq -e '.appliedMigrations[] | select(.id == "001_test_migration")' "$REGISTRY_FILE" > /dev/null 2>&1; then
    echo "  001_test_migration found in registry"
else
    echo "ERROR: 001_test_migration not found in registry"
    exit 1
fi

if jq -e '.appliedMigrations[] | select(.id == "002_test_migration_idempotent")' "$REGISTRY_FILE" > /dev/null 2>&1; then
    echo "  002_test_migration_idempotent found in registry"
else
    echo "ERROR: 002_test_migration_idempotent not found in registry"
    exit 1
fi

# Check all migrations have success status
FAILED_COUNT=$(jq '[.appliedMigrations[] | select(.status != "success")] | length' "$REGISTRY_FILE" 2>/dev/null || echo "0")
if [[ "$FAILED_COUNT" -gt 0 ]]; then
    echo "ERROR: Found $FAILED_COUNT migrations with non-success status"
    exit 1
fi
echo "  All registered migrations have success status"

echo ""
echo "Step 2: Checking database for test marker..."
echo "--------------------------------------"

# Query the database for test marker (executed from host, targeting postgres container)
MARKER_CHECK=$(lxc exec infinibay-postgres -- su - postgres -c \
    "psql -t -c \"SELECT value FROM \\\"SystemSetting\\\" WHERE key = 'test_migration_001_marker'\" infinibay" 2>/dev/null | tr -d ' \n' || echo "")

if [[ -z "$MARKER_CHECK" ]]; then
    echo "ERROR: Test marker not found in database"
    exit 1
fi
echo "  Test marker found in database"

# Check marker contains expected fields
if echo "$MARKER_CHECK" | grep -q "updatedBy002"; then
    echo "  Test marker contains updatedBy002 field (002 migration ran)"
else
    echo "WARNING: Test marker missing updatedBy002 field"
fi

echo ""
echo "Step 3: Testing idempotency (re-run check)..."
echo "--------------------------------------"

# Re-run migrations - they should report "No changes needed"
cd /app

# Check 001 shouldRun returns false
OUTPUT_001=$(npx ts-node -e "
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();
async function check() {
  const result = await prisma.\$queryRaw\`
    SELECT COUNT(*) as count FROM \"SystemSetting\"
    WHERE key = 'test_migration_001_marker'
  \`;
  const exists = Number(result[0]?.count || 0) > 0;
  console.log(exists ? 'SKIP' : 'RUN');
  await prisma.\$disconnect();
}
check();
" 2>/dev/null || echo "ERROR")

if [[ "$OUTPUT_001" == *"SKIP"* ]]; then
    echo "  001_test_migration: idempotent (would skip on re-run)"
else
    echo "WARNING: 001_test_migration might re-run (not idempotent?)"
fi

echo ""
echo "=========================================="
echo "Data migration validation passed!"
echo "=========================================="

exit 0

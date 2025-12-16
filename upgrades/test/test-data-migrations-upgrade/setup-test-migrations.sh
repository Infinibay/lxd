#!/usr/bin/env bash

# setup-test-migrations.sh - Copies test migrations to backend container
#
# This script copies the test data migrations into the backend's data-migrations
# directory so they can be executed by the migration orchestration system.

set -e

echo "=========================================="
echo "Setting up test data migrations..."
echo "=========================================="

# Path to data migrations in backend
MIGRATIONS_DIR="/app/prisma/data-migrations"

# Ensure migrations directory exists
echo "Ensuring migrations directory exists..."
mkdir -p "$MIGRATIONS_DIR"

# Copy test migrations from the test directory
# Note: In a real scenario, migrations would already be in the repo
# For testing, we create them inline

echo "Creating test migration 001_test_migration.ts..."
cat > "$MIGRATIONS_DIR/001_test_migration.ts" << 'MIGRATION_EOF'
import { PrismaClient } from '@prisma/client';

export const migration = {
  id: '001_test_migration',
  description: 'Test migration for upgrade system testing - creates test marker',

  async shouldRun(prisma: PrismaClient): Promise<boolean> {
    console.log('[001_test_migration] Checking if migration should run...');
    try {
      const result = await prisma.$queryRaw<{ count: bigint }[]>`
        SELECT COUNT(*) as count FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;
      const exists = Number(result[0]?.count || 0) > 0;
      console.log(`[001_test_migration] Test marker exists: ${exists}`);
      return !exists;
    } catch (error) {
      console.log('[001_test_migration] Could not check marker, assuming should run');
      return true;
    }
  },

  async up(prisma: PrismaClient): Promise<void> {
    console.log('[001_test_migration] Starting migration...');
    const timestamp = new Date().toISOString();
    try {
      await prisma.$executeRaw`
        INSERT INTO "SystemSetting" (key, value, "createdAt", "updatedAt")
        VALUES (
          'test_migration_001_marker',
          ${JSON.stringify({ migratedAt: timestamp, testId: '001' })},
          NOW(),
          NOW()
        )
        ON CONFLICT (key) DO UPDATE SET
          value = ${JSON.stringify({ migratedAt: timestamp, testId: '001' })},
          "updatedAt" = NOW()
      `;
      console.log(`[001_test_migration] Test marker created at ${timestamp}`);
    } catch (error) {
      console.error('[001_test_migration] Failed to create test marker:', error);
      throw error;
    }
  },

  async down(prisma: PrismaClient): Promise<void> {
    console.log('[001_test_migration] Rolling back migration...');
    try {
      await prisma.$executeRaw`
        DELETE FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;
      console.log('[001_test_migration] Test marker removed');
    } catch (error) {
      console.error('[001_test_migration] Rollback failed:', error);
      throw error;
    }
  },
};

export default migration;

async function main() {
  const prisma = new PrismaClient();
  try {
    const needsRun = await migration.shouldRun(prisma);
    if (!needsRun) {
      console.log(`Migration ${migration.id}: No changes needed, skipping`);
      return;
    }
    await migration.up(prisma);
    console.log(`Migration ${migration.id}: Completed successfully`);
  } catch (error) {
    console.error(`Migration ${migration.id}: Failed with error:`, error);
    process.exit(1);
  } finally {
    await prisma.$disconnect();
  }
}

main();
MIGRATION_EOF

echo "Creating test migration 002_test_migration_idempotent.ts..."
cat > "$MIGRATIONS_DIR/002_test_migration_idempotent.ts" << 'MIGRATION_EOF'
import { PrismaClient } from '@prisma/client';

export const migration = {
  id: '002_test_migration_idempotent',
  description: 'Test idempotent migration behavior - updates test marker',

  async shouldRun(prisma: PrismaClient): Promise<boolean> {
    console.log('[002_test_migration_idempotent] Checking if migration should run...');
    try {
      const result = await prisma.$queryRaw<{ value: string }[]>`
        SELECT value FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;
      if (result.length === 0) {
        console.log('[002_test_migration_idempotent] Test marker from 001 not found, skipping');
        return false;
      }
      const value = JSON.parse(result[0].value);
      const alreadyUpdated = value.updatedBy002 === true;
      console.log(`[002_test_migration_idempotent] Already updated: ${alreadyUpdated}`);
      return !alreadyUpdated;
    } catch (error) {
      console.log('[002_test_migration_idempotent] Could not check marker, assuming should not run');
      return false;
    }
  },

  async up(prisma: PrismaClient): Promise<void> {
    console.log('[002_test_migration_idempotent] Starting migration...');
    const timestamp = new Date().toISOString();
    try {
      const result = await prisma.$queryRaw<{ value: string }[]>`
        SELECT value FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;
      if (result.length === 0) {
        throw new Error('Test marker from 001 not found');
      }
      const currentValue = JSON.parse(result[0].value);
      const newValue = {
        ...currentValue,
        updatedBy002: true,
        updatedAt002: timestamp,
        idempotencyTest: 'This field proves 002 ran',
      };
      await prisma.$executeRaw`
        UPDATE "SystemSetting"
        SET value = ${JSON.stringify(newValue)},
            "updatedAt" = NOW()
        WHERE key = 'test_migration_001_marker'
      `;
      console.log(`[002_test_migration_idempotent] Test marker updated at ${timestamp}`);
    } catch (error) {
      console.error('[002_test_migration_idempotent] Failed:', error);
      throw error;
    }
  },

  async down(prisma: PrismaClient): Promise<void> {
    console.log('[002_test_migration_idempotent] Rolling back...');
  },
};

export default migration;

async function main() {
  const prisma = new PrismaClient();
  try {
    const needsRun = await migration.shouldRun(prisma);
    if (!needsRun) {
      console.log(`Migration ${migration.id}: No changes needed, skipping`);
      return;
    }
    await migration.up(prisma);
    console.log(`Migration ${migration.id}: Completed successfully`);
  } catch (error) {
    console.error(`Migration ${migration.id}: Failed with error:`, error);
    process.exit(1);
  } finally {
    await prisma.$disconnect();
  }
}

main();
MIGRATION_EOF

echo ""
echo "=========================================="
echo "Test migrations setup completed!"
echo "=========================================="

exit 0

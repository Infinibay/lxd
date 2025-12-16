/**
 * Test Data Migration: 002_test_migration_idempotent
 *
 * This test migration validates idempotency and registry tracking.
 * It updates the test marker from 001 with additional data, demonstrating
 * that migrations can be safely re-run.
 *
 * DO NOT USE IN PRODUCTION - This is only for upgrade system testing.
 */

import { PrismaClient } from '@prisma/client';

export const migration = {
  id: '002_test_migration_idempotent',
  description: 'Test idempotent migration behavior - updates test marker',

  /**
   * Check if this migration needs to run.
   * Returns true if the test marker exists but hasn't been updated by this migration.
   */
  async shouldRun(prisma: PrismaClient): Promise<boolean> {
    console.log('[002_test_migration_idempotent] Checking if migration should run...');

    try {
      // Check if test marker from 001 exists and if we've already run
      const result = await prisma.$queryRaw<{ value: string }[]>`
        SELECT value FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;

      if (result.length === 0) {
        console.log('[002_test_migration_idempotent] Test marker from 001 not found, skipping');
        return false;
      }

      // Check if we've already added our update
      const value = JSON.parse(result[0].value);
      const alreadyUpdated = value.updatedBy002 === true;

      console.log(`[002_test_migration_idempotent] Already updated: ${alreadyUpdated}`);
      return !alreadyUpdated;
    } catch (error) {
      console.log('[002_test_migration_idempotent] Could not check marker, assuming should not run');
      return false;
    }
  },

  /**
   * Execute the migration - updates test marker with additional data.
   */
  async up(prisma: PrismaClient): Promise<void> {
    console.log('[002_test_migration_idempotent] Starting migration...');
    console.log('[002_test_migration_idempotent] Updating test marker...');

    const timestamp = new Date().toISOString();

    try {
      // Get current value
      const result = await prisma.$queryRaw<{ value: string }[]>`
        SELECT value FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;

      if (result.length === 0) {
        throw new Error('Test marker from 001 not found - run 001_test_migration first');
      }

      // Update with additional data
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
      console.log('[002_test_migration_idempotent] Migration completed successfully');
    } catch (error) {
      console.error('[002_test_migration_idempotent] Failed to update test marker:', error);
      throw error;
    }
  },

  /**
   * Rollback the migration - removes 002's changes from test marker.
   */
  async down(prisma: PrismaClient): Promise<void> {
    console.log('[002_test_migration_idempotent] Rolling back migration...');

    try {
      // Get current value
      const result = await prisma.$queryRaw<{ value: string }[]>`
        SELECT value FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;

      if (result.length === 0) {
        console.log('[002_test_migration_idempotent] Test marker not found, nothing to rollback');
        return;
      }

      // Remove 002's additions
      const currentValue = JSON.parse(result[0].value);
      const { updatedBy002, updatedAt002, idempotencyTest, ...originalValue } = currentValue;

      await prisma.$executeRaw`
        UPDATE "SystemSetting"
        SET value = ${JSON.stringify(originalValue)},
            "updatedAt" = NOW()
        WHERE key = 'test_migration_001_marker'
      `;

      console.log('[002_test_migration_idempotent] Rollback completed successfully');
    } catch (error) {
      console.error('[002_test_migration_idempotent] Rollback failed:', error);
      throw error;
    }
  },
};

export default migration;

// Main execution block - called by run.sh via ts-node
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

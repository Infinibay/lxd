/**
 * Test Data Migration: 001_test_migration
 *
 * This is a test migration for validating the upgrade system's data migration
 * capabilities. It creates a simple test marker in the database that can be
 * verified during testing.
 *
 * DO NOT USE IN PRODUCTION - This is only for upgrade system testing.
 */

import { PrismaClient } from '@prisma/client';

export const migration = {
  id: '001_test_migration',
  description: 'Test migration for upgrade system testing - creates test marker',

  /**
   * Check if this migration needs to run.
   * Returns true if the test marker doesn't exist yet.
   */
  async shouldRun(prisma: PrismaClient): Promise<boolean> {
    console.log('[001_test_migration] Checking if migration should run...');

    // Check if test marker exists in system settings (using a safe query)
    // We use raw query to avoid schema dependency
    try {
      const result = await prisma.$queryRaw<{ count: bigint }[]>`
        SELECT COUNT(*) as count FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;
      const exists = Number(result[0]?.count || 0) > 0;
      console.log(`[001_test_migration] Test marker exists: ${exists}`);
      return !exists;
    } catch (error) {
      // Table might not exist or different structure - assume should run
      console.log('[001_test_migration] Could not check marker, assuming should run');
      return true;
    }
  },

  /**
   * Execute the migration - creates test marker.
   */
  async up(prisma: PrismaClient): Promise<void> {
    console.log('[001_test_migration] Starting migration...');
    console.log('[001_test_migration] Creating test marker in SystemSetting table...');

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
      console.log('[001_test_migration] Migration completed successfully');
    } catch (error) {
      console.error('[001_test_migration] Failed to create test marker:', error);
      throw error;
    }
  },

  /**
   * Rollback the migration - removes test marker.
   */
  async down(prisma: PrismaClient): Promise<void> {
    console.log('[001_test_migration] Rolling back migration...');

    try {
      await prisma.$executeRaw`
        DELETE FROM "SystemSetting"
        WHERE key = 'test_migration_001_marker'
      `;

      console.log('[001_test_migration] Test marker removed');
      console.log('[001_test_migration] Rollback completed successfully');
    } catch (error) {
      console.error('[001_test_migration] Rollback failed:', error);
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

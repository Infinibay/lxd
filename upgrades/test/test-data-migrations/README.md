# Test Data Migrations

These are test data migrations for validating the upgrade system's data migration capabilities.

**WARNING**: These migrations are for testing purposes only. DO NOT use in production.

## Test Migrations

### 001_test_migration.ts

**Purpose**: Tests basic migration execution and registry tracking.

**What it does**:
- Creates a test marker in the `SystemSetting` table
- Key: `test_migration_001_marker`
- Value: JSON with `migratedAt` timestamp and `testId`

**Verifies**:
- Migration runs when `shouldRun` returns true
- Migration is recorded in `registry.json`
- Migration doesn't run again (registry prevents duplicates)

### 002_test_migration_idempotent.ts

**Purpose**: Tests idempotency and dependent migrations.

**What it does**:
- Updates the test marker created by 001
- Adds `updatedBy002`, `updatedAt002`, and `idempotencyTest` fields

**Verifies**:
- Migrations can safely check for existing data
- `shouldRun` correctly identifies already-applied migrations
- Registry tracking works across multiple migrations

## Using These Migrations

### Setup

1. Copy test migrations to the data-migrations directory:
   ```bash
   cp lxd/upgrades/test/test-data-migrations/*.ts backend/prisma/data-migrations/
   ```

2. Ensure the backend has the Prisma client generated:
   ```bash
   cd backend && npm run db:generate
   ```

### Running

The migrations will run as part of an upgrade that includes a data migration step:

```bash
# Run upgrade that includes data migrations
./run.sh upgrade test-success

# Or run migrations directly (for testing)
cd backend
npx ts-node prisma/data-migrations/001_test_migration.ts
npx ts-node prisma/data-migrations/002_test_migration_idempotent.ts
```

### Verification

1. **Check registry.json**:
   ```bash
   cat backend/prisma/data-migrations/registry.json
   ```

   Expected entries:
   ```json
   {
     "appliedMigrations": [
       {
         "id": "001_test_migration",
         "appliedAt": "2024-...",
         "executionTimeMs": ...,
         "status": "success"
       },
       {
         "id": "002_test_migration_idempotent",
         "appliedAt": "2024-...",
         "executionTimeMs": ...,
         "status": "success"
       }
     ]
   }
   ```

2. **Check database**:
   ```bash
   lxc exec infinibay-postgres -- su - postgres -c \
     "psql -c \"SELECT * FROM \\\"SystemSetting\\\" WHERE key = 'test_migration_001_marker'\" infinibay"
   ```

3. **Test idempotency** (run migrations again):
   ```bash
   npx ts-node prisma/data-migrations/001_test_migration.ts
   # Should output: "No changes needed, skipping"
   ```

4. **Test rollback** (verify database restored after failed upgrade):
   ```bash
   # After running test-migration-fail
   lxc exec infinibay-postgres -- su - postgres -c \
     "psql -c \"SELECT * FROM \\\"SystemSetting\\\" WHERE key = 'test_migration_001_marker'\" infinibay"
   # Should return 0 rows (marker was rolled back with database)
   ```

### Cleanup

After testing, remove test migrations and reset registry:

```bash
# Remove test migration files
rm -f backend/prisma/data-migrations/001_test_migration.ts
rm -f backend/prisma/data-migrations/002_test_migration_idempotent.ts

# Reset registry (if needed)
# WARNING: This removes tracking for ALL migrations
# cat > backend/prisma/data-migrations/registry.json << 'EOF'
# {
#   "appliedMigrations": []
# }
# EOF

# Remove test marker from database
lxc exec infinibay-postgres -- su - postgres -c \
  "psql -c \"DELETE FROM \\\"SystemSetting\\\" WHERE key = 'test_migration_001_marker'\" infinibay"
```

## Migration Registry Structure

The `registry.json` file tracks applied migrations:

```json
{
  "appliedMigrations": [
    {
      "id": "001_test_migration",
      "appliedAt": "2024-01-15T10:30:00.000Z",
      "executionTimeMs": 42,
      "status": "success"
    }
  ]
}
```

This prevents migrations from running twice and provides audit trail.

## Testing Scenarios

### Scenario 1: Fresh Migration Run

1. Copy test migrations to `backend/prisma/data-migrations/`
2. Clear or remove `registry.json`
3. Run migrations
4. Verify both appear in registry with "success" status
5. Verify test marker exists in database

### Scenario 2: Idempotency Test

1. Run migrations (scenario 1)
2. Run migrations again
3. Verify "No changes needed, skipping" for both
4. Verify registry unchanged (no duplicate entries)

### Scenario 3: Rollback Test

1. Run test-migration-fail upgrade
2. Verify database was restored (test marker removed)
3. Verify registry was restored (test entries removed)

## Notes

- These test migrations use `SystemSetting` table which should exist in Infinibay schema
- If `SystemSetting` doesn't exist, modify migrations to use a different table
- Always test on non-production data
- Registry rollback depends on database backup including the registry.json state

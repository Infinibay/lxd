# Test Scenario: test-migration-fail

## Purpose

This test validates **database rollback** when a data migration fails:

- Pre-flight checks pass
- Backup creation succeeds
- Schema migration succeeds
- Data migration **FAILS** (simulated constraint violation)
- Automatic rollback is triggered
- Database is restored to pre-upgrade state (including schema rollback)

## What Gets Tested

1. **Pre-flight Checks**: All pass
2. **Backup Creation**: Full backup of database and code
3. **Upgrade Steps**:
   - Schema migration **SUCCEEDS** (adds column)
   - Data migration **FAILS** (constraint violation)
   - Backend code update should **NOT EXECUTE**
   - Frontend update should **NOT EXECUTE**
4. **Database Rollback**: Full database restoration from backup

## Failure Point

The data migration fails after schema migration succeeds:
- Prisma schema migration adds `testField` column
- Data migration tries to populate `testField`
- **FAILS** with unique constraint violation

Error message:
```
PostgresError: duplicate key value violates unique constraint "VM_testField_key"
  Detail: Key ("testField")=(default-value) already exists.
```

## Expected Outcome

- **Exit Code**: `1` (failure with rollback)
- **Version Unchanged**: `current_version.txt` should still contain `test-base`
- **Database Restored**: Schema reverted (testField column removed)
- **Automatic Rollback**: Full system restoration
- **Backend/Frontend NOT Updated**: Should never execute
- **Migration Registry Unchanged**: `registry.json` should not show failed migration

## Running the Test

### Prerequisites

```bash
# Ensure clean test environment
echo 'test-base' > upgrades/current_version.txt

# Verify all services are running
./run.sh status

# Optional: Note current database state for verification
lxc exec infinibay-postgres -- su - postgres -c "psql -c '\d \"VM\"' infinibay"
```

### Execute Test

```bash
./run.sh upgrade test-migration-fail
```

### Verify Results

```bash
# Check version was NOT updated
cat upgrades/current_version.txt
# Expected output: test-base

# Check backup was created
ls -la /data/backups/

# Verify database was restored (testField column should NOT exist)
lxc exec infinibay-postgres -- su - postgres -c "psql -c '\d \"VM\"' infinibay"

# Check data migration registry was not updated
cat backend/prisma/data-migrations/registry.json

# Verify services are healthy
./run.sh status
```

## Expected Log Output

```
Running pre-flight checks for test-migration-fail upgrade...
All pre-flight checks passed!

Creating backup...
Backup created: /data/backups/test-migration-fail_20XX-XX-XX_XX-XX-XX

Executing upgrade steps...
Step 1/4: update-schema - Applying database schema migrations (succeeds)
  Schema migrations completed successfully!

Step 2/4: run-data-migrations - Running data migrations (WILL FAIL)
  Running data migrations...
  Found 1 unapplied migration: 001_populate_test_field
  Executing 001_populate_test_field...
  ERROR: Migration failed - constraint violation

Step failed. Automatic rollback enabled.
Rolling back...
  Restoring database from backup (includes schema rollback)
  Restoring code from backup
  Restarting services
Rollback completed.

Upgrade failed. System restored to previous state.
```

## Troubleshooting

### Database not properly restored

1. Verify backup contains database dump
2. Check rollback script properly restores PostgreSQL
3. Manually check database schema: `\d "VM"`
4. Compare with pre-upgrade state

### Schema migration artifacts remain

1. Check if rollback restores full database (not just data)
2. Verify Prisma migrations table was restored
3. May need to manually run `prisma migrate reset` in development

## Files

| File | Purpose |
|------|---------|
| `manifest.yml` | Upgrade manifest with multi-step configuration |
| `pre-flight.sh` | Pre-flight check script (should pass) |
| `update-schema.sh` | Simulated schema migration (succeeds) |
| `run-data-migrations-fail.sh` | Simulated data migration that **FAILS** |

# Test Scenario: test-data-migrations-upgrade

## Purpose

This test validates **data migration integration** with the upgrade system:

- Test migrations are set up during upgrade steps
- Migrations are executed via the orchestration system
- Migration registry tracks applied migrations correctly
- Idempotency is verified (migrations don't re-run)
- Database changes are validated

## What Gets Tested

1. **Pre-flight Checks**: All pass
2. **Setup**: Test migrations copied to backend
3. **Data Migrations**: Executed via orchestration system
4. **Registry Tracking**: Migrations recorded in `registry.json`
5. **Database Changes**: Test marker created with expected values
6. **Validation**: Registry and database state verified

## Upgrade Steps

1. `setup-test-migrations`: Copies test migration files to backend
2. `run-data-migrations`: Executes migrations, updates registry
3. `update-backend`: Simulated backend update
4. `update-frontend`: Simulated frontend update

## Validation Checks

1. **health-check**: Container and database connectivity
2. **validate-migrations**:
   - Registry file exists and is valid JSON
   - Both test migrations appear in registry
   - All migrations have "success" status
   - Test marker exists in database
   - Migrations are idempotent (would skip on re-run)

## Expected Outcome

- **Exit Code**: `0` (success)
- **Version Updated**: `current_version.txt` contains `test-data-migrations-upgrade`
- **Registry Updated**: Both migrations in `registry.json`
- **Database Updated**: Test marker exists with `updatedBy002` field

## Running the Test

### Prerequisites

```bash
# Ensure clean test environment
echo 'test-base' > upgrades/current_version.txt

# Verify all services are running
./run.sh status
```

### Execute Test

```bash
./run.sh upgrade test-data-migrations-upgrade
```

### Verify Results

```bash
# Check version updated
cat upgrades/current_version.txt
# Expected: test-data-migrations-upgrade

# Check registry (from backend container)
lxc exec infinibay-backend -- cat /app/prisma/data-migrations/registry.json | jq '.'
# Should show both migrations with "success" status

# Check database marker
lxc exec infinibay-postgres -- su - postgres -c \
  "psql -c \"SELECT * FROM \\\"SystemSetting\\\" WHERE key = 'test_migration_001_marker'\" infinibay"
# Should show row with JSON containing updatedBy002

# Test idempotency (run upgrade again)
./run.sh upgrade test-data-migrations-upgrade
# Migrations should skip ("No changes needed")
```

## Rollback Verification

After a failed upgrade with rollback:

```bash
# Registry should be restored (no test migrations)
lxc exec infinibay-backend -- cat /app/prisma/data-migrations/registry.json | jq '.'

# Test marker should be removed (database restored)
lxc exec infinibay-postgres -- su - postgres -c \
  "psql -c \"SELECT * FROM \\\"SystemSetting\\\" WHERE key = 'test_migration_001_marker'\" infinibay"
# Should return 0 rows
```

## Files

| File | Purpose |
|------|---------|
| `manifest.yml` | Upgrade manifest with data migration step |
| `pre-flight.sh` | Pre-flight checks (should pass) |
| `setup-test-migrations.sh` | Copies test migrations to backend |
| `run-data-migrations.sh` | Executes migrations via orchestration |
| `update-backend.sh` | Simulated backend update |
| `update-frontend.sh` | Simulated frontend update |
| `validate-health.sh` | Health checks |
| `validate-migrations.sh` | Migration registry and database validation |

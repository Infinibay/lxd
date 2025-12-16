# Test Scenario: test-build-fail

## Purpose

This test validates the **automatic rollback mechanism** when a build step fails:

- Pre-flight checks pass
- Backup creation succeeds
- Backend build step fails (simulated TypeScript errors)
- Automatic rollback is triggered
- System is restored to pre-upgrade state

## What Gets Tested

1. **Pre-flight Checks**: All pass to allow upgrade to proceed
2. **Backup Creation**: Full backup of database and code
3. **Upgrade Steps**:
   - Backend update starts but **FAILS** during build
   - Frontend update should **NOT EXECUTE** (depends on backend)
4. **Automatic Rollback**: System restored from backup

## Failure Point

The backend build fails after:
- Git pull succeeds
- npm install succeeds
- npm run build **FAILS** with TypeScript compilation errors

Error messages simulate real TypeScript errors:
```
error TS2307: Cannot find module '@infinibay/types/missing'
error TS2339: Property 'invalidMethod' does not exist on type 'VMService'
error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'
```

## Expected Outcome

- **Exit Code**: `1` (failure with rollback)
- **Version Unchanged**: `current_version.txt` should still contain `test-base`
- **Backup Created**: Backup should exist in `/data/backups/`
- **Automatic Rollback**: System restored to pre-upgrade state
- **Frontend NOT Updated**: Frontend update should never execute
- **Services Healthy**: All services should be running after rollback

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
./run.sh upgrade test-build-fail
```

### Verify Results

```bash
# Check version was NOT updated (should still be test-base)
cat upgrades/current_version.txt
# Expected output: test-base

# Check backup was created
ls -la /data/backups/

# Verify rollback occurred (check logs)
# Look for "Rolling back" or "Rollback completed" messages

# Verify services are healthy after rollback
./run.sh status
```

## Expected Log Output

```
Running pre-flight checks for test-build-fail upgrade...
  Disk space check passed
  infinibay-postgres is running
  infinibay-redis is running
  infinibay-backend is running
  infinibay-frontend is running
  Database connectivity check passed
All pre-flight checks passed!

Creating backup...
Backup created: /data/backups/test-build-fail_20XX-XX-XX_XX-XX-XX

Executing upgrade steps...
Step 1/2: update-backend - Simulating backend update (WILL FAIL)
  Git pull (simulated)
  npm install (simulated)
  npm run build (simulated)
  ERROR: Build failed - TypeScript compilation error

Step failed. Automatic rollback enabled.
Rolling back...
  Restoring database from backup
  Restoring code from backup
  Restarting services
Rollback completed.

Upgrade failed. System restored to previous state.
```

## Troubleshooting

### Rollback not triggered

1. Check if `rollback_on_fail: true` is set for the step
2. Check if `rollback.automatic: true` is set in manifest
3. Review upgrade script output for errors

### System not restored properly

1. Verify backup was created successfully
2. Check rollback script output for errors
3. Manually verify database state
4. Check git commit hashes in repositories

## Files

| File | Purpose |
|------|---------|
| `manifest.yml` | Upgrade manifest with rollback configuration |
| `pre-flight.sh` | Pre-flight check script (should pass) |
| `update-backend-fail.sh` | Simulated backend update that **FAILS** |

# Test Scenario: test-health-fail

## Purpose

This test validates **automatic rollback when post-upgrade validation fails**:

- All pre-flight checks pass
- Backup creation succeeds
- **All upgrade steps succeed**
- Post-upgrade health check **FAILS**
- Automatic rollback is triggered
- System is restored to pre-upgrade state

## What Gets Tested

1. **Pre-flight Checks**: All pass
2. **Backup Creation**: Full backup of database and code
3. **Upgrade Steps**:
   - Backend update **SUCCEEDS**
   - Frontend update **SUCCEEDS**
4. **Validation**: Backend health check **FAILS**
5. **Automatic Rollback**: System restored despite successful upgrade steps

## Failure Point

The upgrade fails **after all steps complete**:
- Backend update completes successfully
- Frontend update completes successfully
- Validation phase begins
- Backend health check **FAILS** (simulated HTTP 500 from /health endpoint)

This tests the critical scenario where code deploys successfully but the
application doesn't work correctly.

## Expected Outcome

- **Exit Code**: `1` (failure with rollback)
- **Version Unchanged**: `current_version.txt` should still contain `test-base`
- **Backup Created**: Backup should exist in `/data/backups/`
- **Rollback Triggered**: Full restoration from backup
- **Services Healthy**: After rollback, all services should be working

## Running the Test

### Prerequisites

```bash
# Ensure clean test environment
echo 'test-base' > upgrades/current_version.txt

# Verify all services are running and healthy
./run.sh status
```

### Execute Test

```bash
./run.sh upgrade test-health-fail
```

### Verify Results

```bash
# Check version was NOT updated
cat upgrades/current_version.txt
# Expected output: test-base

# Check backup was created
ls -la /data/backups/

# Verify rollback occurred (system restored)
./run.sh status

# Services should be healthy after rollback
curl http://localhost:4000/health  # Backend
curl http://localhost:3000         # Frontend
```

## Expected Log Output

```
Running pre-flight checks for test-health-fail upgrade...
All pre-flight checks passed!

Creating backup...
Backup created: /data/backups/test-health-fail_20XX-XX-XX_XX-XX-XX

Executing upgrade steps...
Step 1/2: update-backend - Updating backend (succeeds)
  Backend update completed successfully!

Step 2/2: update-frontend - Updating frontend (succeeds)
  Frontend update completed successfully!

All upgrade steps completed. Running validation...

Running post-upgrade health checks...
  Backend service is active
  Checking backend API health endpoint...

==========================================
ERROR: Backend health check failed
==========================================

Details:
  Endpoint: http://localhost:4000/health
  Expected: HTTP 200 OK
  Received: HTTP 500 Internal Server Error

Critical validation failed. Automatic rollback enabled.
Rolling back...
  Restoring database from backup
  Restoring code from backup
  Restarting services
Rollback completed.

Upgrade failed. System restored to previous state.
```

## Key Verification Points

1. **All upgrade steps completed** before failure
2. **Validation triggered rollback** (not an upgrade step failure)
3. **Full restoration** occurred (not partial)
4. **Services healthy** after rollback
5. **Backup was used** for restoration

## Troubleshooting

### Services not healthy after rollback

1. Check if rollback properly restarted services
2. Verify database was restored correctly
3. Check for partial state that wasn't rolled back
4. Review rollback script for completeness

### Rollback not triggered

1. Verify health check has `critical: true` in manifest
2. Check if `rollback.automatic: true` is set
3. Review upgrade command's validation handling

## Files

| File | Purpose |
|------|---------|
| `manifest.yml` | Upgrade manifest with critical validation |
| `pre-flight.sh` | Pre-flight check script (passes) |
| `update-backend.sh` | Backend update (succeeds) |
| `update-frontend.sh` | Frontend update (succeeds) |
| `validate-health-fail.sh` | Health check that **FAILS** |

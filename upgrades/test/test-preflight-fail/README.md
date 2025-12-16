# Test Scenario: test-preflight-fail

## Purpose

This test validates that **upgrades are blocked** when required pre-flight checks fail:

- Pre-flight check fails (simulated insufficient disk space)
- Upgrade aborts immediately
- No backup is created
- No upgrade steps are executed
- No rollback needed (system unchanged)

## What Gets Tested

1. **Pre-flight Checks**: Required check **FAILS** (disk space)
2. **Upgrade Blocked**: System rejects upgrade before any changes
3. **No Side Effects**: No backup created, no modifications made
4. **User Feedback**: Clear error message with actionable hints

## Failure Point

The upgrade fails at the very first step:
- Pre-flight disk space check runs
- **FAILS** with simulated "insufficient disk space" error
- Upgrade aborts before backup creation

## Expected Outcome

- **Exit Code**: `1` (failure, but no rollback needed)
- **Version Unchanged**: `current_version.txt` should still contain `test-base`
- **No Backup Created**: `/data/backups/` should not have new backup
- **No Changes Made**: System completely unchanged
- **Clear Error Message**: User sees actionable hints

## Running the Test

### Prerequisites

```bash
# Ensure clean test environment
echo 'test-base' > upgrades/current_version.txt

# Note current backup count for verification
ls /data/backups/ | wc -l
```

### Execute Test

```bash
./run.sh upgrade test-preflight-fail
```

### Verify Results

```bash
# Check version was NOT updated
cat upgrades/current_version.txt
# Expected output: test-base

# Verify NO new backup was created
ls /data/backups/
# Should NOT contain test-preflight-fail_* backup

# Verify system is unchanged
./run.sh status
```

## Expected Log Output

```
Checking upgrade manifest for test-preflight-fail...
Manifest valid.

Running pre-flight checks...
Checking disk space...

==========================================
ERROR: Insufficient disk space for upgrade
==========================================

Details:
  Location: /data/backups
  Available: 500MB
  Required: 2GB minimum

The upgrade cannot proceed without sufficient disk space
for creating a backup of your current system.

Hint: Free up disk space before upgrading:
  - Remove old backups: rm -rf /data/backups/old_*
  - Clean up unused VMs: ./run.sh vm cleanup
  - Check disk usage: df -h /data/backups

Pre-flight check failed. Upgrade aborted.
No changes were made to your system.
```

## Key Verification Points

1. **No backup directory** with `test-preflight-fail_*` prefix
2. **No rollback triggered** (nothing to roll back)
3. **Services remain running** (no restarts)
4. **Database unchanged** (no migrations applied)
5. **Git commits unchanged** in all repositories

## Troubleshooting

### Upgrade proceeded despite failure

1. Check if pre-flight check has `required: true`
2. Verify pre-flight script returns exit code 1
3. Review upgrade command implementation for proper error handling

### Backup was created

1. This indicates pre-flight checks ran AFTER backup
2. Verify upgrade command runs pre-flight BEFORE backup
3. This is a bug in the upgrade system if it happens

## Files

| File | Purpose |
|------|---------|
| `manifest.yml` | Upgrade manifest with required pre-flight check |
| `pre-flight-fail.sh` | Pre-flight script that **ALWAYS FAILS** |

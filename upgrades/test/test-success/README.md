# Test Scenario: test-success

## Purpose

This test validates the **happy path** of the upgrade system where everything succeeds:

- All pre-flight checks pass
- Backup creation succeeds
- All upgrade steps execute successfully
- All validation checks pass
- Version is updated correctly

## What Gets Tested

1. **Pre-flight Checks**: Disk space, container status, database connectivity
2. **Backup Creation**: Full backup of database and code
3. **Upgrade Steps**:
   - Backend update (simulated git pull, npm install, build)
   - Frontend update (simulated git pull, npm install, build)
4. **Health Validation**: Service status, database connection

## Expected Outcome

- **Exit Code**: `0` (success)
- **Version Updated**: `current_version.txt` should contain `test-success`
- **Backup Created**: New backup directory in `/data/backups/`
- **Services Healthy**: All containers running, services active
- **No Rollback**: Rollback should NOT be triggered

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
./run.sh upgrade test-success
```

### Verify Results

```bash
# Check version was updated
cat upgrades/current_version.txt
# Expected output: test-success

# Check backup was created
ls -la /data/backups/

# Verify services are healthy
./run.sh status
```

## Troubleshooting

### Upgrade fails unexpectedly

1. Check pre-flight output for specific failures
2. Verify disk space: `df -h /data/backups`
3. Check container status: `lxc list`
4. Review logs: `./run.sh logs backend`

### Version not updated

1. Check if upgrade completed without errors
2. Verify `current_version.txt` permissions
3. Check upgrade script exit codes

## Files

| File | Purpose |
|------|---------|
| `manifest.yml` | Upgrade manifest defining the test |
| `pre-flight.sh` | Pre-flight check script (should pass) |
| `update-backend.sh` | Simulated backend update (should succeed) |
| `update-frontend.sh` | Simulated frontend update (should succeed) |
| `validate-health.sh` | Health check script (should pass) |

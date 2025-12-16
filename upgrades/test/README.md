# Upgrade System Test Suite

This directory contains test upgrade manifests designed to validate the Infinibay upgrade system's error handling and rollback capabilities.

**WARNING**: These are test manifests for validation purposes only. DO NOT use in production environments.

## Test Scenarios

| Scenario | Purpose | Expected Outcome |
|----------|---------|------------------|
| `test-success` | Validates happy path | Upgrade completes, version updated |
| `test-build-fail` | Tests build failure rollback | Automatic rollback, version unchanged |
| `test-migration-fail` | Tests data migration failure | Database restored, version unchanged |
| `test-preflight-fail` | Tests pre-flight check blocking | Upgrade aborted, no changes made |
| `test-health-fail` | Tests post-upgrade validation | Rollback after successful steps |

## Prerequisites

Before running tests:

1. **Clean LXD Environment**: Start with a fresh Infinibay installation
   ```bash
   ./run.sh destroy
   ./run.sh apply
   ./run.sh provision
   ```

2. **Set Test Base Version**: Configure the starting version
   ```bash
   echo 'test-base' > upgrades/current_version.txt
   ```

3. **Verify Services**: Ensure all containers are running and healthy
   ```bash
   ./run.sh status
   ```

## Running Tests

### Run Individual Tests

```bash
# Successful upgrade test
./run.sh upgrade test-success

# Build failure test
./run.sh upgrade test-build-fail

# Migration failure test
./run.sh upgrade test-migration-fail

# Pre-flight failure test
./run.sh upgrade test-preflight-fail

# Health check failure test
./run.sh upgrade test-health-fail
```

### Run All Tests

```bash
cd upgrades/test
./run-all-tests.sh
```

### Run with Verbose Output

```bash
./run-all-tests.sh --verbose
```

## Test Artifacts

After running tests, check:

- **Backups**: `/data/backups/` - Contains backups created during tests
- **Logs**: `./run.sh logs backend` / `./run.sh logs frontend`
- **Version File**: `upgrades/current_version.txt` - Should match expected state
- **Data Migration Registry**: `backend/prisma/data-migrations/registry.json`

## Cleanup

After testing, clean up test artifacts:

```bash
# Remove test backups
rm -rf /data/backups/test_*

# Reset version file
echo 'test-base' > upgrades/current_version.txt

# Remove test data migrations (if copied)
rm -f backend/prisma/data-migrations/001_test_*.ts
rm -f backend/prisma/data-migrations/002_test_*.ts
```

## Detailed Documentation

For complete testing procedures, troubleshooting, and CI/CD integration, see:
- `lxd/TESTING.md` - Comprehensive testing documentation

## Test Structure

Each test scenario follows this structure:

```
test-{scenario}/
├── manifest.yml       # Upgrade manifest defining the test
├── pre-flight.sh      # Pre-flight check script
├── update-*.sh        # Upgrade step scripts
├── validate-*.sh      # Validation scripts (if applicable)
└── README.md          # Scenario-specific documentation
```

## Adding New Tests

To add a new test scenario:

1. Create a new directory: `test-{scenario-name}/`
2. Create a `manifest.yml` following the schema in `upgrades/v0.3.0/manifest.yml`
3. Create the required scripts (pre-flight, update steps, validation)
4. Add scenario documentation in `README.md`
5. Update this README and `run-all-tests.sh`

## Notes

- Tests are designed to be run on isolated LXD environments
- Each test may modify system state; reset between tests
- Test scripts simulate real upgrade scenarios with controlled failures
- Rollback verification is critical for failure tests

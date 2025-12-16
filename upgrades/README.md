# Infinibay Versioned Upgrades System

This directory contains versioned upgrade manifests for Infinibay. Each upgrade is defined by a YAML manifest that specifies pre-flight checks, upgrade steps, validation, and rollback procedures.

## Directory Structure

```
lxd/upgrades/
├── current_version.txt       # Tracks installed version
├── v0.3.0/                   # Example upgrade to v0.3.0
│   ├── manifest.yml          # Upgrade definition
│   ├── pre-flight.sh         # Pre-flight checks
│   ├── check-vms.sh          # VM status check
│   └── README.md             # User-facing upgrade notes
├── v0.4.0/                   # Future upgrade
│   └── ...
└── README.md                 # This file
```

## Upgrade vs Update

**Update** (`./run.sh update`):
- Pulls latest code from git repositories
- Rebuilds and restarts services
- Runs Prisma schema migrations and data migrations
- Suitable for minor updates and bug fixes
- No version tracking

**Upgrade** (`./run.sh upgrade <version>`):
- Versioned, manifest-driven process
- Custom pre-flight checks per version
- Breaking changes notification
- Version-specific upgrade steps
- Post-upgrade validation
- Version tracking in `current_version.txt`
- Suitable for major releases with breaking changes

## Manifest Format

Each upgrade version has a `manifest.yml` file with the following structure:

```yaml
version: "0.3.0"              # Target version
from_version: "0.2.0"         # Required current version
description: "Brief description of changes"

breaking_changes:             # Displayed to user before upgrade
  - "API change description"
  - "Database schema change"

pre_flight:                   # Checks before backup
  - name: "check-name"
    script: "script.sh"
    required: true/false      # Block upgrade if fails?
    message: "Optional warning message"

backup:                       # Backup configuration
  database: true
  redis: false
  code: true

steps:                        # Upgrade steps (executed in order)
  - name: "step-name"
    container: "container-name"
    script: "path/to/script.sh"
    description: "What this step does"
    timeout: 600              # Seconds
    rollback_on_fail: true    # Trigger rollback if fails
    depends_on: ["other-step"]  # Optional dependencies

validation:                   # Post-upgrade checks
  - name: "check-name"
    script: "test-script.sh"
    critical: true/false      # Trigger rollback if fails

rollback:                     # Rollback configuration
  automatic: true             # Auto-rollback on failure
  steps:                      # Custom rollback steps (optional)
    - name: "rollback-step"
      script: "rollback-script.sh"
```

## Creating a New Upgrade

1. **Create version directory**:
   ```bash
   mkdir lxd/upgrades/v0.4.0
   cd lxd/upgrades/v0.4.0
   ```

2. **Create manifest.yml**:
   - Copy from `v0.3.0/manifest.yml` as template
   - Update version, from_version, description
   - Define breaking changes
   - Specify pre-flight checks
   - Define upgrade steps
   - Configure validation checks

3. **Create upgrade scripts**:
   - Pre-flight checks: `pre-flight.sh`
   - Upgrade steps: `backend/update.sh`, `frontend/update.sh`, etc.
   - Validation: `test-backend.sh`, `test-frontend.sh`, etc.
   - Rollback scripts: `rollback-backend.sh`, `rollback-database.sh`, etc.

   **IMPORTANT**: All scripts (pre-flight, step, validation, and rollback) must be executable.
   The upgrade system will warn during validation if scripts are not executable, but they
   will fail at runtime. Make scripts executable with:
   ```bash
   chmod +x pre-flight.sh check-vms.sh
   chmod +x test-backend.sh test-frontend.sh test-queries.sh
   chmod +x rollback-backend.sh rollback-frontend.sh rollback-database.sh
   # Or make all scripts executable at once:
   chmod +x *.sh
   ```

4. **Create README.md**:
   - Explain what's new in this version
   - Document breaking changes
   - Provide post-upgrade instructions
   - Include rollback information

5. **Test the upgrade**:
   - Test on a clean environment
   - Verify pre-flight checks work
   - Test successful upgrade path
   - Test rollback on failure
   - Verify validation checks

## Usage

**List available upgrades**:
```bash
./run.sh upgrade --list
```

**Upgrade to specific version**:
```bash
./run.sh upgrade v0.3.0
```

**Check current version**:
```bash
cat lxd/upgrades/current_version.txt
```

## Upgrade Process

When you run `./run.sh upgrade v0.3.0`, the system:

1. **Loads manifest** - Parses `v0.3.0/manifest.yml`
2. **Checks compatibility** - Verifies current version matches `from_version`
3. **Shows breaking changes** - Displays changes and asks for confirmation
4. **Runs pre-flight checks** - Executes checks defined in manifest
5. **Creates backup** - Full backup (database + git state)
6. **Executes upgrade steps** - Runs each step in order
7. **Validates upgrade** - Runs post-upgrade checks
8. **Updates version** - Writes new version to `current_version.txt`
9. **Shows post-upgrade notes** - Displays README.md

If any critical step fails, the system automatically rolls back to the backup.

## Rollback

If an upgrade fails or you need to revert:

```bash
./run.sh rollback
```

This restores:
- Database to pre-upgrade state
- Code to previous git commits
- Full rebuild of all services
- Version in `current_version.txt`

## Best Practices

1. **Version Compatibility**:
   - Each upgrade should specify exactly one `from_version`
   - Don't skip versions (upgrade 0.2.0 -> 0.3.0 -> 0.4.0, not 0.2.0 -> 0.4.0)

2. **Pre-flight Checks**:
   - Check disk space, container status, database connectivity
   - Mark critical checks as `required: true`
   - Provide helpful error messages

3. **Upgrade Steps**:
   - Keep steps atomic and focused
   - Set appropriate timeouts (Rust builds need 10+ minutes)
   - Mark critical steps with `rollback_on_fail: true`
   - Use dependencies (`depends_on`) for ordering

4. **Validation**:
   - Test all critical services (backend, frontend, database)
   - Mark essential checks as `critical: true`
   - Include both automated tests and health checks

5. **Documentation**:
   - Document breaking changes clearly
   - Provide migration paths for deprecated features
   - Include post-upgrade steps users need to take
   - Explain rollback implications

6. **Testing**:
   - Test on a clean environment first
   - Test both success and failure paths
   - Verify rollback works correctly
   - Test with running VMs

## Troubleshooting

**"Upgrade v0.3.0 not found"**:
- Check that `lxd/upgrades/v0.3.0/manifest.yml` exists
- Verify manifest.yml is valid YAML

**"Cannot upgrade from X to Y"**:
- Check current version: `cat lxd/upgrades/current_version.txt`
- Verify manifest's `from_version` matches current version
- You may need to upgrade incrementally (0.2.0 -> 0.3.0 -> 0.4.0)

**"yq command not found"**:
- Install yq: `sudo snap install yq` or `sudo apt install yq`

**Pre-flight checks fail**:
- Review error messages for specific issues
- Fix issues and retry upgrade
- Common issues: disk space, stopped containers, database connectivity

**Upgrade fails mid-process**:
- System automatically rolls back if `rollback_on_fail: true`
- Check logs: `./run.sh logs backend` or `./run.sh logs frontend`
- Review backup: `ls -la /data/backups/`
- Manual rollback: `./run.sh rollback`

## Version History

- **0.2.0** - Initial version with upgrade system
- **0.3.0** - Adds firewall presets, VM scheduling, department management

## See Also

- Update system design: `lxd/UPDATE_SYSTEM_DESIGN.md`
- Update guide: `lxd/UPDATE_GUIDE.md` (Phase 12)
- Backup system: `lxd/lib/backup.sh`
- Rollback system: `lxd/lib/rollback.sh`

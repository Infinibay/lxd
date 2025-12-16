# Infinibay Update & Upgrade Guide

This guide provides comprehensive documentation for the Infinibay update/upgrade system, including when to use each command, troubleshooting common issues, and managing backups.

## Table of Contents

1. [Overview](#overview)
2. [Update vs Upgrade: When to Use Which](#update-vs-upgrade-when-to-use-which)
3. [Update Command](#update-command)
4. [Upgrade Command](#upgrade-command)
5. [Backup Management](#backup-management)
6. [Rollback Procedures](#rollback-procedures)
7. [Troubleshooting Common Issues](#troubleshooting-common-issues)
8. [FAQ](#faq)
9. [Advanced Topics](#advanced-topics)

---

## Overview

The Infinibay update/upgrade system provides atomic updates with automatic backups and rollback capabilities. Key features:

- **Atomic Updates**: All changes applied together or rolled back completely
- **Automatic Backups**: Database and git state saved before any changes
- **Rollback on Failure**: System restored to previous state if any step fails
- **Health Checks**: Services verified after update/upgrade
- **Progress Indicators**: Real-time feedback on current step and elapsed time
- **Detailed Error Messages**: Context-aware troubleshooting guidance

### Design Principles

1. **Safety First**: Never leave the system in an inconsistent state
2. **Data Preservation**: Database always backed up before modifications
3. **Transparency**: Clear progress indicators and error messages
4. **Recoverability**: Easy rollback from any failure

---

## Update vs Upgrade: When to Use Which

Use this decision tree to choose the right command:

```
Do you need a specific version?
├─ Yes → Use UPGRADE
└─ No → Are there breaking changes?
    ├─ Yes → Use UPGRADE
    └─ No → Is this for production?
        ├─ Yes → Use UPGRADE (with tested versions)
        └─ No → Use UPDATE
```

### Update Command

**Purpose**: Pull latest changes from main branch across all repositories

**Best for**:
- Development and testing environments
- Staying current with bug fixes
- Quick iteration during development
- Non-breaking changes

**Characteristics**:
- Fast (10-20 minutes)
- Automatic dependency resolution
- Always pulls latest from main branch
- No version control

### Upgrade Command

**Purpose**: Perform versioned upgrades with manifest-driven orchestration

**Best for**:
- Production environments
- Major version upgrades
- Breaking changes requiring manual steps
- Coordinated multi-repo changes
- Custom data migrations

**Characteristics**:
- Controlled, tested releases
- Version compatibility checking
- Custom pre/post scripts per version
- Breaking changes documented
- Incremental upgrades required

---

## Update Command

### Basic Usage

```bash
./run.sh update
./run.sh u        # Shortcut
./run.sh up       # Shortcut
```

### What Happens

The update command executes in phases with progress indicators:

**Phase 0: LXD Self-Update**
- Fetches latest LXD scripts from remote
- Re-executes if run.sh changed
- Ensures update script itself is current

**Phase 1: Backup**
- Creates timestamped backup of database
- Records git commit hashes for all repos
- Validates backup integrity

**Phase 2: Update Repositories**

*Phase 2.1: libvirt-node*
- Check for updates
- Pull changes
- Install npm dependencies
- Build Rust module (5-10 minutes)
- Verify .node file created
- Package and copy to backend

*Phase 2.2: backend*
- Pull changes
- Install dependencies (if needed)
- Build TypeScript
- Generate Prisma client
- Apply database migrations
- Run data migrations (if any)
- Restart service

*Phase 2.3: frontend*
- Pull changes
- Install dependencies (if needed)
- Run GraphQL codegen
- Build Next.js application
- Restart service

**Phase 3: Health Checks**
- PostgreSQL connectivity
- Redis connectivity
- Backend API response
- Frontend HTTP response

### Prerequisites

Before running update:

1. **All containers must be running**
   ```bash
   ./run.sh status
   # If not running:
   ./run.sh apply
   ```

2. **No uncommitted changes in repositories**
   ```bash
   # Check backend
   lxc exec infinibay-backend -- git -C /opt/infinibay/backend status
   ```

3. **Sufficient disk space** (at least 2GB free)
   ```bash
   df -h /data
   ```

4. **Backup directory writable**
   ```bash
   lxc exec infinibay-postgres -- ls -ld /data/backups
   ```

### Success Indicators

When update completes successfully:

```
✓ Phase 0: LXD Self-Update completed (12s)
✓ Phase 1: Backup completed (45s)
✓ Phase 2.1: Update libvirt-node completed (6m 23s)
✓ Phase 2.2: Update Backend completed (2m 12s)
✓ Phase 2.3: Update Frontend completed (1m 45s)
✓ Phase 3: Health Checks completed (28s)

╔══════════════════════════════════════════════════════════════╗
║         Update Completed Successfully!                       ║
╚══════════════════════════════════════════════════════════════╝

Backup available at: /data/backups/update_20250130_153000
```

### Estimated Duration

| Phase | Duration |
|-------|----------|
| Backup | 1-2 minutes |
| libvirt-node | 5-10 minutes |
| backend | 2-3 minutes |
| frontend | 1-2 minutes |
| Health checks | 30 seconds - 1 minute |
| **Total** | **10-20 minutes** |

---

## Upgrade Command

### Basic Usage

```bash
./run.sh upgrade --list              # List available upgrades
./run.sh upgrade --dry-run v0.3.0    # Preview upgrade
./run.sh upgrade v0.3.0              # Perform upgrade
./run.sh ug v0.3.0                   # Shortcut
```

### Listing Available Upgrades

```bash
./run.sh upgrade --list
```

Shows:
- Current version
- Available upgrade versions
- Compatibility information
- Breaking changes summary

### Previewing an Upgrade (Dry Run)

```bash
./run.sh upgrade --dry-run v0.3.0
```

Displays:
- Pre-flight checks that would run
- Upgrade steps with descriptions
- Validation checks
- No changes made to the system

### Performing an Upgrade

```bash
./run.sh upgrade v0.3.0
```

The upgrade proceeds through these steps:

1. **Load Manifest**: Parse and validate manifest.yml
2. **Version Check**: Verify current version matches from_version
3. **Display Summary**: Show upgrade details and breaking changes
4. **User Confirmation**: Require explicit approval
5. **Pre-flight Checks**: Run version-specific validation
6. **Create Backup**: Tagged with version transition
7. **Execute Steps**: Run upgrade scripts in order
8. **Validation**: Verify upgrade succeeded
9. **Health Checks**: Confirm services healthy
10. **Update Version**: Write new version to current_version.txt
11. **Post-upgrade Notes**: Display any required user actions

### Understanding Manifests

Upgrade manifests are located in `lxd/upgrades/<version>/manifest.yml`:

```yaml
version: "0.3.0"
from_version: "0.2.0"
description: "Major update with new firewall system"

breaking_changes:
  - "Firewall API completely rewritten"
  - "Old firewall templates deprecated"

pre_flight:
  - name: "Check database connectivity"
    script: "checks/db-check.sh"
    required: true

steps:
  - name: "Migrate firewall rules"
    container: "infinibay-backend"
    script: "steps/migrate-firewall.sh"
    timeout: 600
    rollback_on_fail: true

validation:
  - name: "Verify firewall migration"
    script: "validation/check-firewall.sh"
    critical: true

post_notes:
  - "Review new firewall documentation"
  - "Update any custom firewall scripts"
```

### Incremental Upgrades

You cannot skip versions. To upgrade from v0.2.0 to v0.4.0:

```bash
./run.sh upgrade v0.2.5   # First upgrade
./run.sh upgrade v0.3.0   # Second upgrade
./run.sh upgrade v0.4.0   # Third upgrade
```

---

## Backup Management

### Backup Types

| Type | Created By | Retention | Format |
|------|------------|-----------|--------|
| Manual | User (`./run.sh backup`) | Never deleted | `manual_<label>_<timestamp>` |
| Update | Update command | 30 days | `update_<timestamp>` |
| Upgrade | Upgrade command | 30 days | `upgrade_<from>_to_<to>_<timestamp>` |
| Scheduled | Cron (if enabled) | 7 days or last 10 | `scheduled_<timestamp>` |

### Creating Manual Backups

```bash
./run.sh backup                        # Auto-generated label
./run.sh backup --label "before-test"  # Custom label
```

### Listing Backups

```bash
./run.sh backup --list
```

### Cleaning Old Backups

Apply retention policy:

```bash
./run.sh backup --clean
```

### Enabling Scheduled Backups

```bash
./run.sh backup --enable-schedule   # Daily at 2 AM
./run.sh backup --disable-schedule  # Disable
```

### Backup Contents

Each backup includes:
- `infinibay_backup.sql` - PostgreSQL database dump
- `backend_commit.txt` - Backend repo commit hash
- `frontend_commit.txt` - Frontend repo commit hash
- `lxd_commit.txt` - LXD repo commit hash
- `libvirt-node_commit.txt` - Libvirt-node repo commit hash
- `*_status.txt` - Uncommitted changes warnings (if any)
- `metadata.json` - Backup metadata

**Not included**:
- Redis data (ephemeral cache)
- VM disk images
- Log files

### Backup Location

- **Host path**: `/data/backups/` (default LXD setup)
- **Container path**: `/data/backups/` (inside infinibay-postgres)

Access via:
```bash
lxc exec infinibay-postgres -- ls /data/backups
```

---

## Rollback Procedures

### Automatic Rollback

When update/upgrade fails, the system automatically:

1. Stops affected services
2. Restores database from backup
3. Resets git repositories to previous commits
4. Rebuilds all affected components
5. Restarts services
6. Verifies system health

No user action required.

### Manual Rollback

Use when:
- Update/upgrade succeeded but caused issues
- Need to revert to a specific backup
- Testing or troubleshooting

**Steps:**

1. List available backups:
   ```bash
   ./run.sh backup --list
   ```

2. Identify backup to restore (e.g., `update_20250124_153000`)

3. Stop containers:
   ```bash
   ./run.sh stop
   ```

4. Restore database:
   ```bash
   # Drop and recreate database
   lxc exec infinibay-postgres -- su - postgres -c "dropdb infinibay"
   lxc exec infinibay-postgres -- su - postgres -c "createdb infinibay"

   # Restore from backup
   lxc exec infinibay-postgres -- su - postgres -c \
     "psql infinibay < /data/backups/update_20250124_153000/infinibay_backup.sql"
   ```

5. Reset git repositories:
   ```bash
   # Read commit hash from backup
   lxc exec infinibay-backend -- cat /data/backups/update_20250124_153000/backend_commit.txt

   # Reset to that commit
   lxc exec infinibay-backend -- su - infinibay -c \
     "cd /opt/infinibay/backend && git reset --hard <commit-hash>"
   ```

6. Rebuild:
   ```bash
   lxc exec infinibay-backend -- su - infinibay -c \
     "cd /opt/infinibay/backend && rm -rf node_modules dist && npm install && npm run build"
   ```

7. Restart services:
   ```bash
   ./run.sh restart
   ```

### Rollback Limitations

- Cannot restore Redis data (ephemeral)
- Cannot restore VM disk images
- Cannot restore logs
- Uncommitted changes are lost

---

## Troubleshooting Common Issues

### Pre-flight Check Failures

#### Containers not running

```bash
# Check status
./run.sh status

# Start containers
./run.sh apply

# If containers fail to start, check logs
./run.sh logs <container-name>
```

#### Uncommitted changes

```bash
# Check for uncommitted changes
lxc exec infinibay-backend -- git -C /opt/infinibay/backend status

# Commit changes
lxc exec infinibay-backend -- su - infinibay -c \
  "cd /opt/infinibay/backend && git add . && git commit -m 'WIP'"

# Or stash them
lxc exec infinibay-backend -- su - infinibay -c \
  "cd /opt/infinibay/backend && git stash"
```

#### Insufficient disk space

```bash
# Check disk space
df -h /data

# Clean old backups
./run.sh backup --clean

# Or manually delete old backups
lxc exec infinibay-postgres -- rm -rf /data/backups/old_backup_name
```

#### Backup directory not writable

```bash
# Check permissions
lxc exec infinibay-postgres -- ls -ld /data/backups

# Fix permissions
lxc exec infinibay-postgres -- chown -R postgres:postgres /data/backups
lxc exec infinibay-postgres -- chmod 755 /data/backups
```

### Build Failures

#### libvirt-node Rust compilation failed

```bash
# Check Rust version
lxc exec infinibay-backend -- su - infinibay -c "rustc --version"

# Check libvirt headers
lxc exec infinibay-backend -- dpkg -l | grep libvirt-dev

# Check disk space
lxc exec infinibay-backend -- df -h /opt/infinibay

# Check build logs (if available)
lxc exec infinibay-backend -- cat /opt/infinibay/libvirt-node/build.log
```

Common causes:
- Rust toolchain version mismatch
- Missing libvirt development headers
- Insufficient disk space
- Memory exhaustion during compilation

#### Backend TypeScript build failed

```bash
# Check Node.js version
lxc exec infinibay-backend -- node --version

# Check for TypeScript errors
lxc exec infinibay-backend -- su - infinibay -c \
  "cd /opt/infinibay/backend && npx tsc --noEmit"

# Check Prisma schema
lxc exec infinibay-backend -- su - infinibay -c \
  "cd /opt/infinibay/backend && npx prisma validate"
```

Common causes:
- TypeScript compilation errors
- Breaking changes in GraphQL schema
- Missing npm dependencies
- Prisma schema validation errors

#### Frontend build failed

```bash
# Check Node.js version
lxc exec infinibay-frontend -- node --version

# Regenerate GraphQL hooks
lxc exec infinibay-frontend -- su - infinibay -c \
  "cd /opt/infinibay/frontend && npm run codegen"

# Check for TypeScript errors
lxc exec infinibay-frontend -- su - infinibay -c \
  "cd /opt/infinibay/frontend && npx tsc --noEmit"
```

Common causes:
- GraphQL codegen errors (schema mismatch)
- TypeScript/JSX compilation errors
- Next.js build configuration issues

### Migration Failures

#### Prisma schema migration failed

```bash
# Check migration status
lxc exec infinibay-backend -- su - infinibay -c \
  "cd /opt/infinibay/backend && npx prisma migrate status"

# Check database connection
lxc exec infinibay-backend -- su - infinibay -c \
  "cd /opt/infinibay/backend && npx prisma db pull --print"

# View PostgreSQL logs
lxc exec infinibay-postgres -- journalctl -u postgresql -n 50
```

**Important**: Do NOT retry migrations manually after failure. Let the automatic rollback complete, then investigate the cause.

#### Data migration failed

```bash
# Check data migration registry
lxc exec infinibay-backend -- cat \
  /opt/infinibay/backend/prisma/data-migrations/registry.json
```

### Health Check Failures

#### PostgreSQL

```bash
# Check service status
lxc exec infinibay-postgres -- systemctl status postgresql

# Check logs
lxc exec infinibay-postgres -- journalctl -u postgresql -n 50

# Test connection
lxc exec infinibay-postgres -- su - postgres -c "psql -c 'SELECT 1'"
```

#### Redis

```bash
# Check service status
lxc exec infinibay-redis -- systemctl status redis

# Check logs
lxc exec infinibay-redis -- journalctl -u redis -n 50

# Test connection
lxc exec infinibay-redis -- redis-cli ping
```

#### Backend

```bash
# Check service status
lxc exec infinibay-backend -- systemctl status infinibay-backend

# Check logs
lxc exec infinibay-backend -- journalctl -u infinibay-backend -n 50

# Test GraphQL endpoint
curl -s http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{__schema{types{name}}}"}'
```

#### Frontend

```bash
# Check service status
lxc exec infinibay-frontend -- systemctl status infinibay-frontend

# Check logs
lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -n 50

# Test HTTP endpoint
curl -sI http://localhost:3000 | head -1
```

### Git Operation Failures

#### Failed to fetch updates

- Check network connectivity
- Verify git remote: `git remote -v`
- Check SSH keys or credentials
- Try manual fetch: `git fetch origin`

#### Failed to pull updates

- Check for merge conflicts
- Check for detached HEAD state
- If conflicts exist: `git reset --hard origin/main`

---

## FAQ

### How long does an update take?

Typically 10-20 minutes. The libvirt-node Rust compilation is the longest step (5-10 minutes).

### Can I cancel an update in progress?

Not recommended. If you must, press Ctrl+C. The system may be in an inconsistent state. Run manual rollback afterward.

### What happens if my SSH connection drops during update?

The update continues in the background. Reconnect and check status:
```bash
./run.sh status
./run.sh logs <container>
```

### Can I update individual repositories?

No. Individual repo updates were removed for safety. Always update all repos together to maintain consistency.

### How do I know which version I'm running?

```bash
cat lxd/current_version.txt
# Or
./run.sh upgrade --list
```

### Can I skip versions when upgrading?

No. Upgrade incrementally through intermediate versions:
```bash
./run.sh upgrade v0.2.5
./run.sh upgrade v0.3.0
./run.sh upgrade v0.4.0
```

### What if I have uncommitted changes?

Pre-flight checks will fail. Commit or stash changes before updating:
```bash
# Commit
git add . && git commit -m "WIP"

# Or stash
git stash
```

### Are my VMs affected by updates?

VMs continue running but may lose connectivity briefly during backend restart. Check for running VMs:
```bash
./run.sh stop --check-vms
```

### How do I test an update before applying?

- For upgrades: `./run.sh upgrade --dry-run <version>`
- For updates: Test in a separate LXD environment first

### Can I automate updates?

Not recommended for production. Updates require monitoring. For development, you could script it but ensure proper error handling.

### What's the difference between update and upgrade backups?

Same content, different retention policies:
- Update backups: 30 days
- Upgrade backups: 30 days
- Manual backups: Never deleted automatically

---

## Advanced Topics

### Custom Upgrade Manifests

Create custom upgrade manifests in `lxd/upgrades/<version>/`:

```yaml
# manifest.yml
version: "0.4.0"
from_version: "0.3.0"
description: "Your upgrade description"

breaking_changes:
  - "List breaking changes"

pre_flight:
  - name: "Custom check"
    script: "checks/custom.sh"
    required: true

steps:
  - name: "Migration step"
    container: "infinibay-backend"
    script: "steps/migrate.sh"
    timeout: 600
    rollback_on_fail: true

validation:
  - name: "Verify migration"
    script: "validation/verify.sh"
    critical: true

post_notes:
  - "Post-upgrade instructions"
```

### Data Migrations

For complex data transformations:

1. Create migration in `backend/prisma/data-migrations/`
2. Follow naming: `YYYYMMDD_description.js`
3. Export `up()` and `down()` functions
4. Register in `registry.json`

### Testing Updates/Upgrades

1. Create test LXD environment
2. Clone production data
3. Run update/upgrade
4. Verify functionality
5. Test rollback

---

## Related Documentation

- `lxd/run.sh help-update` - Update command reference
- `lxd/run.sh help-upgrade` - Upgrade command reference
- `backend/prisma/data-migrations/README.md` - Data migrations guide
- `lxd/upgrades/<version>/README.md` - Version-specific notes

---

*For additional help or to report issues, visit: https://github.com/infinibay/infinibay/issues*

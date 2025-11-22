# Infinibay LXD Deployment

LXD-based containerization for the Infinibay VDI management platform.

## Status

✅ **Production Ready** - Automated provisioning with intelligent orchestration and multi-distro support

## Quick Links

- **[INSTALL.md](./INSTALL.md)** - ⭐ Complete installation and deployment guide
- **Project Root**: [../](../)
- **Installer Reference**: [../installer/](../installer/)

## Why LXD?

LXD provides native support for KVM/libvirt, making it ideal for running VMs inside containers without privileged mode or complex workarounds.

**Key advantages:**
- ✅ Native KVM device access - no `--privileged` mode needed
- ✅ Full systemd support inside containers
- ✅ Designed for nested virtualization
- ✅ YAML-based configuration (lxd-compose)
- ✅ Better security isolation for VM workloads
- ✅ Minimal performance overhead (~5%)

### Supported Operating Systems

Infinibay's LXD deployment supports multiple Linux distributions with automatic package manager detection:

- **Debian/Ubuntu** - Uses `apt-get` (auto-detected)
- **RHEL/CentOS/Fedora/Rocky/AlmaLinux** - Uses `dnf` or `yum` (auto-detected)
- **openSUSE/SLES** - Uses `zypper` (auto-detected)
- **Arch/Manjaro/EndeavourOS** - Uses `pacman` (auto-detected)

The setup script automatically detects your distribution and uses the appropriate package manager. LXD installation path (snap vs native package) is also auto-detected.

## Overview

This directory contains LXD-based containerization for Infinibay using **lxd-compose**.

**Structure:**
```
lxd/
├── run.sh                         # Main management script ⭐
├── .lxd-compose.yml               # Main lxd-compose config
├── envs/
│   └── infinibay.yml              # Infinibay project definition
├── profiles/
│   └── templates/                 # LXD profile templates
├── values.yml.example             # Configuration template
├── setup.sh                       # Automated installation
├── INSTALL.md                     # Complete guide
└── README.md                      # This file
```

**Note:** lxd-compose uses a different structure than docker-compose:
- Main config: `.lxd-compose.yml`
- Projects: `envs/*.yml` files
- Commands: `apply infinibay`, `destroy infinibay`, `stop infinibay`

## Architecture

The deployment creates 4 LXD containers:

1. **infinibay-postgres** - PostgreSQL database
2. **infinibay-redis** - Redis cache
3. **infinibay-backend** - Node.js API + libvirt-node + infiniservice + KVM access
4. **infinibay-frontend** - Next.js web interface

## Quick Start

```bash
# 1. Clone repository and navigate to lxd directory
cd infinibay/lxd

# 2. Run setup (installs LXD, lxd-compose, detects package manager)
sudo ./setup.sh

# 3. IMPORTANT: Activate lxd group (REQUIRED!)
newgrp lxd
# This activates the group in your current session
# You need to do this after setup.sh adds you to the lxd group

# 4. Configure environment variables
# Option A: Edit the auto-generated .env (RECOMMENDED)
nano .env
# setup.sh already created .env with secure auto-generated passwords
# IMPORTANT: Change ADMIN_PASSWORD from auto-generated to your own!

# Option B: If you prefer to start from .env.example before setup.sh
# cp .env.example .env && nano .env
# Then run setup.sh, which will detect and preserve your .env

# 5. Deploy and start Infinibay (smart default - does everything!)
./run.sh
# This one command:
# - Creates containers if they don't exist
# - Starts containers if they're stopped
# - Provisions if not already done (installs PostgreSQL, Redis, Node.js, Rust, libvirt)
# - Shows access URLs when ready
# Takes 5-10 minutes on first run

# 6. Access Infinibay
# URLs will be displayed after ./run.sh completes
# Frontend: http://<frontend-ip>:3000
# Backend API: http://<backend-ip>:4000
```

**What happens:**
- `setup.sh` - Installs LXD, lxd-compose, detects your distro and package manager, auto-detects LXD path, generates `.env` with secure passwords
- `newgrp lxd` - ⚠️ **REQUIRED** - Activates lxd group permissions
- `.env configuration` - ⚠️ **IMPORTANT** - Review and change ADMIN_PASSWORD (auto-generated passwords should be personalized!)
- `./run.sh` - Intelligent orchestration: creates containers, provisions software, starts everything
  - Checks if environment exists → creates if not
  - Checks if containers are running → starts if stopped
  - Checks if provisioned → provisions if not (tracked via LXD metadata)
  - Skips already-completed steps automatically
- Containers have shared `/opt/infinibay` directory (your code)
- Data persists in `/data` directories even if containers are destroyed

## Important: Group Membership

After running `setup.sh`, you may need to activate the `lxd` group:

**Option 1 (Quick - current session only):**
```bash
newgrp lxd
```

**Option 2 (Permanent - requires re-login):**
```bash
logout
# Then login again
```

**How to check if you're in the group:**
```bash
groups | grep lxd
# Should show 'lxd' in the output
```

## Common Operations

### Recommended Workflow (Smart Default)

```bash
# One command does everything - creates, provisions, and starts
./run.sh              # Smart default - handles everything automatically

# Fresh start - destroy and recreate everything
./run.sh redo         # or: ./run.sh rd

# Quick status check
./run.sh status       # or: ./run.sh s
```

### Using run.sh (All Commands)

```bash
# Smart default workflow (recommended)
./run.sh              # Does everything: create → provision → start

# Manual step-by-step (if you prefer explicit control)
./run.sh apply        # Shortcuts: a, ap - Create containers
./run.sh provision    # Shortcuts: p, pr - Install software

# Container management
./run.sh status       # Shortcuts: s, st - Check status
./run.sh destroy      # Shortcuts: d, de - Remove containers
./run.sh redo         # Shortcut: rd - Destroy and recreate (fresh start)
./run.sh restart      # Shortcuts: r, re - Legacy alias for redo

# Execute commands in containers
./run.sh exec backend bash      # Shortcuts: e, ex
./run.sh exec postgres psql -U infinibay
./run.sh exec frontend npm run dev

# Follow container logs
./run.sh logs backend           # Shortcuts: l, lo
./run.sh logs postgres

# Update profiles only (after modifying templates)
./run.sh setup-profiles         # Shortcut: sp

# Show help with all shortcuts
./run.sh help
```

**Complete shortcut reference:**
| Command | Shortcuts | Description |
|---------|-----------|-------------|
| `apply` | `a`, `ap` | Create and start containers |
| `provision` | `p`, `pr` | Install software in containers |
| `redo` | `rd` | Destroy and recreate everything |
| `destroy` | `d`, `de` | Stop and remove all containers |
| `restart` | `r`, `re` | Legacy alias for redo |
| `status` | `s`, `st` | Show container status |
| `setup-profiles` | `sp` | Update LXD profiles only |
| `exec` | `e`, `ex` | Execute command in container |
| `logs` | `l`, `lo` | Follow container logs |

### Direct LXC Commands

```bash
# View container status
sg lxd -c "lxc list"

# Execute commands
sg lxd -c "lxc exec infinibay-backend -- bash"

# Create snapshot
sg lxd -c "lxc snapshot infinibay-backend backup-$(date +%Y%m%d)"

# List snapshots
lxc info infinibay-backend
```

## Current Status

**Implemented and Working:**
- ✅ Creates 4 Ubuntu containers with resource limits
- ✅ Mounts shared `/opt/infinibay` directory (your code)
- ✅ Persistent `/data` directories for each service
- ✅ Automated provisioning scripts for all containers
- ✅ PostgreSQL installation and configuration
- ✅ Redis installation and configuration
- ✅ Node.js 20.x LTS + npm
- ✅ Rust toolchain (for libvirt-node native modules)
- ✅ libvirt + KVM with /dev/kvm device access
- ✅ Systemd services ready for backend/frontend
- ✅ Network connectivity between containers
- ✅ Universal package manager support (apt/dnf/zypper/pacman)
- ✅ Automatic LXD path detection (snap vs native)
- ✅ Smart default orchestration with state tracking
- ✅ Provisioning state persistence via LXD metadata

**Still Manual:**
- ⏳ npm install in backend/frontend
- ⏳ Database migrations
- ⏳ Starting Infinibay services
- ⏳ Application configuration

**After provisioning, you need to:**
1. Install npm dependencies in backend/frontend
2. Run database migrations
3. Configure and start Infinibay services

See [INSTALL.md](./INSTALL.md) for detailed instructions.

## Troubleshooting

### "No project selected" error
```bash
# Make sure you specify the project name
lxd-compose apply infinibay  # ✓ Correct
lxd-compose apply             # ✗ Wrong
```

### "Unable to read the configuration file" error
```bash
# You need to be in the lxd group
newgrp lxd
# Or logout/login
```

### "Permission denied" on LXD socket
```bash
# Check if you're in lxd group
groups | grep lxd

# If not, the setup script should have added you
# Just run:
newgrp lxd
```

### Smart default fails at provisioning step
```bash
# Check individual container status
./run.sh status

# Use redo to start fresh (destroys and recreates everything)
./run.sh redo
```

### Want to force re-provisioning
```bash
# Option 1: Use redo command (destroys and recreates everything)
./run.sh redo

# Option 2: Manually clear provisioning state for specific container
lxc config unset infinibay-backend user.provisioned
lxc config unset infinibay-frontend user.provisioned
lxc config unset infinibay-postgres user.provisioned
lxc config unset infinibay-redis user.provisioned
# Then run: ./run.sh
```

## vs Native Installer

| Aspect | LXD (Current) | Native Installer |
|--------|---------------|------------------|
| **Status** | 🚧 In Development | ✅ Production Ready |
| **Provisioning** | Manual for now | ✅ Fully automated |
| **Isolation** | ✅ Full container isolation | ❌ System-wide |
| **Rollback** | ✅ Snapshots | ❌ Manual |
| **Complexity** | Medium | Low |

**Recommendation:** Use the [native installer](../installer/) for production deployments until LXD provisioning is complete.

## Contributing

See [INSTALL.md](./INSTALL.md) for development workflows.

## References

- [LXD Documentation](https://documentation.ubuntu.com/lxd/)
- [lxd-compose Documentation](https://mottainaici.github.io/lxd-compose-docs/)
- [Infinibay Installer](../installer/) - **Recommended for production**

---

**Last Updated**: 2025-11-21
**Status**: Production Ready

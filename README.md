# Infinibay LXD Deployment

LXD-based containerization for the Infinibay VDI management platform.

## Status

⚠️ **Work in Progress** - Basic structure complete, container provisioning in development

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

# 2. Run setup (installs LXD, lxd-compose, Go)
sudo ./setup.sh

# 3. IMPORTANT: Activate lxd group (REQUIRED!)
newgrp lxd
# This activates the group in your current session
# You need to do this after setup.sh adds you to the lxd group

# 4. Configure deployment
cp values.yml.example values.yml
nano values.yml  # Edit database passwords, IPs, etc.

# 5. Deploy containers
./run.sh apply

# 6. Provision containers (install software)
./run.sh provision
# This installs PostgreSQL, Redis, Node.js, Rust, libvirt
# Takes 5-10 minutes

# 7. Check status
./run.sh status

# 8. Access containers
./run.sh exec backend bash
./run.sh exec postgres bash
```

**What happens:**
- `setup.sh` - Installs LXD, lxd-compose, Go
- `newgrp lxd` - ⚠️ **REQUIRED** - Activates lxd group permissions
- `./run.sh apply` - Creates and starts empty containers
- `./run.sh provision` - Installs all software inside containers
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

### Using run.sh (Recommended)

```bash
# Initial setup workflow
./run.sh apply      # Create and start containers
./run.sh provision  # Install software (PostgreSQL, Redis, Node.js, etc.)

# Container management
./run.sh status     # Check container status
./run.sh destroy    # Stop and remove all containers
./run.sh restart    # Destroy and recreate containers

# Execute commands in containers
./run.sh exec backend bash
./run.sh exec postgres psql -U infinibay
./run.sh exec frontend npm run dev

# Follow container logs
./run.sh logs backend
./run.sh logs postgres

# Update profiles only (after modifying templates)
./run.sh setup-profiles

# Show help
./run.sh help
```

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

**Last Updated**: 2025-11-20
**Status**: Basic Structure Complete, Provisioning In Progress

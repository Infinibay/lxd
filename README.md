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
├── .lxd-compose.yml               # Main lxd-compose config
├── envs/
│   └── infinibay.yml              # Infinibay project definition
├── .env.example                   # Environment template
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
# 1. Clone repository
git clone https://github.com/infinibay/infinibay.git
cd infinibay/lxd

# 2. Run setup (installs LXD, lxd-compose, creates .env)
sudo ./setup.sh

# 3. IMPORTANT: If setup added you to lxd group, activate it
newgrp lxd
# (or logout/login for permanent effect)

# 4. Review configuration
nano .env

# 5. Verify project is recognized
lxd-compose project list

# 6. Deploy containers
lxd-compose apply infinibay

# 7. Check status
lxc list
```

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

```bash
# Deploy/update project
lxd-compose apply infinibay

# Destroy project (removes all containers)
lxd-compose destroy infinibay

# Stop containers (keeps them, just stops)
lxd-compose stop infinibay

# View project info
lxd-compose project list

# View container status
lxc list

# View logs (after provisioning)
lxc exec infinibay-backend -- journalctl -f

# Open shell in container
lxc exec infinibay-backend -- bash

# Create snapshot
lxc snapshot infinibay-backend backup-$(date +%Y%m%d)

# List snapshots
lxc info infinibay-backend
```

## Current Limitations

⚠️ The current implementation creates basic containers but **does not yet**:
- Install application dependencies (Node.js, PostgreSQL, etc.)
- Configure libvirt/KVM access
- Set up cloud-init provisioning
- Mount /dev/kvm device
- Configure networking between containers

**What it does:**
- ✅ Creates 4 Ubuntu containers
- ✅ Sets resource limits (CPU, RAM)
- ✅ Configures basic networking

**Next steps needed:**
1. Add cloud-init hooks for software installation
2. Configure device mounts (KVM, libvirt socket)
3. Add network configuration between containers
4. Add startup scripts and systemd services

See [INSTALL.md](./INSTALL.md) for detailed configuration options.

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

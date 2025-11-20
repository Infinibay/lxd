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
- Commands: `apply`, `destroy`, `stop` (not `up`/`down`)

## Architecture

The deployment creates 4 LXD containers:

1. **infinibay-postgres** - PostgreSQL database
2. **infinibay-redis** - Redis cache
3. **infinibay-backend** - Node.js API + libvirt-node + infiniservice + KVM access
4. **infinibay-frontend** - Next.js web interface

## Quick Start

```bash
# Clone repository
git clone https://github.com/infinibay/infinibay.git
cd infinibay/lxd

# Run setup (installs LXD, lxd-compose, creates .env)
sudo ./setup.sh

# Review configuration
nano .env

# Verify project is recognized
lxd-compose project list

# Deploy containers (NOTE: Basic provisioning only for now)
lxd-compose apply

# Check status
lxc list
```

## Common Operations

```bash
# Deploy/update project
lxd-compose apply

# Destroy project
lxd-compose destroy

# Stop containers
lxd-compose stop

# View project info
lxd-compose project list

# View container status
lxc list

# View logs (after provisioning)
lxc exec infinibay-backend -- journalctl -f

# Open shell in container
lxc exec infinibay-backend -- bash
```

## Current Limitations

⚠️ The current implementation creates basic containers but **does not yet**:
- Install application dependencies (Node.js, PostgreSQL, etc.)
- Configure libvirt/KVM access
- Set up cloud-init provisioning
- Mount /dev/kvm device
- Configure networking between containers

**Next steps needed:**
1. Add cloud-init hooks for software installation
2. Configure device mounts (KVM, libvirt socket)
3. Add network configuration
4. Add startup scripts and systemd services

See [INSTALL.md](./INSTALL.md) for detailed configuration options.

## vs Native Installer

| Aspect | LXD (Current) | Native Installer |
|--------|---------------|------------------|
| **Status** | 🚧 In Development | ✅ Production Ready |
| **Provisioning** | Manual for now | ✅ Fully automated |
| **Isolation** | ✅ Full container isolation | ❌ System-wide |
| **Rollback** | ✅ Snapshots | ❌ Manual |

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

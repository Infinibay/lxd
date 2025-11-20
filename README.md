# Infinibay LXD Deployment

LXD-based containerization for the Infinibay VDI management platform.

## Status

✅ **Implementation Complete** - Ready for deployment

## Quick Links

- **[INSTALL.md](./INSTALL.md)** - ⭐ Complete installation and deployment guide (START HERE)
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

This directory contains LXD-based containerization for Infinibay, including:

- `lxd-compose.yml` - Multi-container orchestration configuration
- `setup.sh` - Automated installation script
- `.env.example` - Environment configuration template
- `INSTALL.md` - Complete deployment guide

## Architecture

Infinibay uses a multi-service architecture:

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Frontend   │────▶│   Backend    │────▶│  PostgreSQL   │
│  (Next.js)  │     │  (GraphQL)   │     │               │
└─────────────┘     └──────────────┘     └───────────────┘
                            │
                            ├────────────▶ Redis (cache)
                            │
                            ├────────────▶ Infiniservice (RPC)
                            │
                            └────────────▶ libvirt (KVM/QEMU)
```

**Note:** `infiniservice` and `libvirt-node` are not separate containers. They run inside the backend container:
- **libvirt-node**: Rust library compiled as NAPI-RS addon (imported by backend)
- **infiniservice**: Rust binary executed by backend via RPC

## LXD Containers

The deployment creates 4 LXD containers:

1. **infinibay-postgres** - PostgreSQL database
2. **infinibay-redis** - Redis cache (98% performance improvement for firewall rules)
3. **infinibay-backend** - Node.js GraphQL API + libvirt-node + infiniservice + KVM access
4. **infinibay-frontend** - Next.js web interface

## Configurable Parameters

All installer parameters can be configured via environment variables in `.env`:

| Category | Parameters |
|----------|------------|
| **Database** | DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD |
| **Admin** | ADMIN_EMAIL, ADMIN_PASSWORD |
| **Network** | HOST_IP, LIBVIRT_NETWORK_NAME, BACKEND_PORT, FRONTEND_PORT |
| **Application** | INFINIBAY_BASE_DIR, SKIP_ISO_DOWNLOAD, REDIS_ENABLED |
| **Resources** | BACKEND_CPU_LIMIT, BACKEND_MEMORY_LIMIT, etc. |

See [INSTALL.md](./INSTALL.md) for complete parameter reference.

## Structure

```
lxd/
├── README.md                       # This file
├── INSTALL.md                      # Complete deployment guide
├── lxd-compose.yml                 # Multi-container orchestration
├── .env.example                    # Environment configuration template
└── setup.sh                        # Automated installation script
```

## Quick Start

```bash
# Clone repository
git clone https://github.com/infinibay/infinibay.git
cd infinibay/lxd

# Run setup (installs LXD, lxd-compose, creates .env)
sudo ./setup.sh

# Review and customize configuration
nano .env

# Deploy all containers
lxd-compose up

# Access Infinibay
# Frontend: http://<YOUR_IP>:3000
# GraphQL API: http://<YOUR_IP>:4000/graphql
```

**See [INSTALL.md](./INSTALL.md) for detailed installation and usage guide.**

## Common Operations

```bash
# Start all containers
lxd-compose up

# Stop all containers
lxd-compose down

# View container status
lxc list

# View logs
lxc exec infinibay-backend -- journalctl -u infinibay-backend -f

# Execute migrations
lxc exec infinibay-backend -- npm run db:migrate

# Open shell in container
lxc exec infinibay-backend -- bash

# Backup database
lxc exec infinibay-postgres -- su - postgres -c "pg_dump infinibay" > backup.sql

# Create snapshot before updates
lxc snapshot infinibay-backend backup-$(date +%Y%m%d)
```

For complete documentation, see [INSTALL.md](./INSTALL.md).

## Goals

1. **Simplicity**: Single `lxd-compose up` deployment
2. **Portability**: Run on any LXD-compatible host
3. **Security**: Proper secrets management, no privileged mode required
4. **Performance**: Native KVM access, minimal overhead (~5%)
5. **Maintainability**: Snapshots, easy rollback, isolated environments

## Advantages vs Native Installer

| Aspect | LXD | Native Installer |
|--------|-----|------------------|
| **Installation Time** | ~15 min | ~20-30 min |
| **Isolation** | ✅ Full container isolation | ❌ System-wide |
| **Updates** | ✅ Snapshots before updates | ⚠️ Re-run installer |
| **Rollback** | ✅ Instant (snapshots) | ❌ Manual |
| **Portability** | ✅ Export/import containers | ❌ Tied to host |
| **Resource Usage** | ~5% overhead | 0% (native) |

## Contributing

See [INSTALL.md](./INSTALL.md) for development workflows and troubleshooting.

## License

Same as Infinibay project (MIT License).

## References

- [LXD Documentation](https://documentation.ubuntu.com/lxd/)
- [lxd-compose](https://mottainaici.github.io/lxd-compose-docs/)
- [Infinibay Installer](../installer/) - Native installation approach
- [Backend CLAUDE.md](../backend/CLAUDE.md) - Backend architecture
- [Frontend CLAUDE.md](../frontend/CLAUDE.md) - Frontend architecture
- [Project Philosophy](../PHILOSOPHY.md) - Design principles

---

**Last Updated**: 2025-11-20
**Status**: Production Ready

# Infinibay Containerization

Containerization for the Infinibay VDI management platform using **LXD**.

## Status

✅ **LXD Implementation Complete** - Docker research available as alternative.

## Quick Links

- **[LXD.md](./LXD.md)** - ⭐ Complete LXD deployment guide (START HERE)
- **[RESEARCH.md](./RESEARCH.md)** - Research findings comparing Docker vs LXD
- **Project Root**: [../](../)
- **Installer Reference**: [../installer/](../installer/)

## Why LXD Instead of Docker?

**TL;DR**: LXD has native support for KVM/libvirt, making it ideal for running VMs inside containers.

| Feature | LXD | Docker |
|---------|-----|--------|
| **KVM Access** | ✅ Native | ⚠️ Requires `--privileged` |
| **Nested Virtualization** | ✅ Designed for it | ⚠️ Limited |
| **Systemd Support** | ✅ Full | ❌ Not recommended |
| **Configuration** | ✅ YAML (lxd-compose) | ✅ YAML (docker-compose) |

See [RESEARCH.md](./RESEARCH.md) for detailed comparison and Docker implementation option.

## Overview

This directory contains Docker-related files for containerizing Infinibay, including:

- Multi-stage Dockerfiles for each service (backend, frontend, infiniservice, libvirt-node)
- Docker Compose orchestration files
- Entrypoint scripts and configuration
- CI/CD workflows for DockerHub publishing

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

## Goals

1. **Simplicity**: Single `docker-compose up` deployment
2. **Portability**: Run on any Docker-compatible host
3. **Optimization**: <500MB total image size via multi-stage builds
4. **Security**: Proper secrets management, non-root containers
5. **CI/CD**: Automated builds and publishing to DockerHub

## Key Technical Challenges

### 1. KVM/libvirt Access
Docker containers need access to `/dev/kvm` for virtualization. Solutions:
- Device passthrough: `--device /dev/kvm`
- Privileged mode (less preferred): `--privileged`

### 2. Multi-Service Orchestration
Infinibay has 6+ services that need coordinated startup:
- PostgreSQL (database)
- Redis (cache)
- Backend (API)
- Frontend (UI)
- Infiniservice (orchestration)
- libvirtd (VM management)

### 3. Build Complexity
Components require compilation in specific order:
1. libvirt-node (Rust → NAPI-RS)
2. Backend (depends on libvirt-node)
3. Frontend (independent)
4. Infiniservice (Rust with Windows cross-compile)

**Solution**: Multi-stage Docker builds with layer caching

## Configurable Parameters

All installer parameters can be configured via environment variables:

| Category | Parameters |
|----------|------------|
| **Database** | DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD |
| **Admin** | ADMIN_EMAIL, ADMIN_PASSWORD |
| **Network** | HOST_IP, LIBVIRT_NETWORK_NAME, BACKEND_PORT, FRONTEND_PORT |
| **Application** | INFINIBAY_BASE_DIR, SKIP_ISO_DOWNLOAD, REDIS_ENABLED |

See [RESEARCH.md](./RESEARCH.md#configurable-parameters) for complete list.

## Structure

```
docker/
├── README.md                       # This file
├── LXD.md                          # Complete LXD deployment guide
├── RESEARCH.md                     # Research findings (Docker vs LXD)
├── lxd-compose.yml                 # LXD orchestration (like docker-compose)
├── .env.example                    # Environment variable template
├── setup.sh                        # Automated setup script
└── profiles/                       # (Future) Custom LXD profiles
```

**Note**: This directory was originally named "docker" during research phase, but contains LXD implementation.

## Quick Start

```bash
# Clone repository
git clone https://github.com/infinibay/infinibay.git
cd infinibay/docker

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

**See [LXD.md](./LXD.md) for detailed installation and usage guide.**

## Development Workflow (Planned)

```bash
# Development mode with hot reload
docker-compose -f docker-compose.yml -f docker-compose.dev.yml up

# Run specific service
docker-compose up backend

# View logs
docker-compose logs -f backend

# Execute migrations
docker-compose exec backend npm run db:migrate

# Run tests
docker-compose exec backend npm test
```

## DockerHub Publishing

Images will be published to DockerHub via GitHub Actions:

- `infinibay/backend:latest`
- `infinibay/frontend:latest`
- `infinibay/infiniservice:latest`
- `infinibay/libvirt-node:latest`

Automated builds trigger on:
- Push to `main` branch → `latest` tag
- Git tags `v*` → versioned tags (e.g., `v1.0.0`)

## Research Findings Summary

From [RESEARCH.md](./RESEARCH.md):

### Docker Best Practices (2025)
- **Multi-stage builds**: 70-85% image size reduction
- **Alpine/distroless base images**: Security + minimal size
- **cargo-chef for Rust**: 5x faster Docker builds
- **Never use ARG/ENV for secrets**: Use Docker secrets or volume mounts

### Recommended Approach
- **Orchestration**: Docker Compose (development/SMBs), Kubernetes (future/enterprise)
- **Process Management**: tini/dumb-init, NOT systemd
- **Security**: Non-root users, secret mounts, minimal attack surface
- **CI/CD**: GitHub Actions → DockerHub (with access tokens)

## Contributing

This is currently in research/planning phase. Implementation will follow the roadmap in [RESEARCH.md](./RESEARCH.md#implementation-roadmap).

## License

Same as Infinibay project (MIT License).

## References

- [Infinibay Installer](../installer/) - Native installation approach
- [Backend CLAUDE.md](../backend/CLAUDE.md) - Backend architecture
- [Frontend CLAUDE.md](../frontend/CLAUDE.md) - Frontend architecture
- [Project Philosophy](../PHILOSOPHY.md) - Design principles

---

**Last Updated**: 2025-11-20
**Status**: Research Complete, Implementation Pending

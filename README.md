# Infinibay Docker

Docker containerization for the Infinibay VDI management platform.

## Status

🚧 **In Development** - Research phase completed, implementation in progress.

## Quick Links

- **[RESEARCH.md](./RESEARCH.md)** - Comprehensive research findings on Docker best practices, technical challenges, and implementation strategy
- **Project Root**: [../](../)
- **Installer Reference**: [../installer/](../installer/)

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

## Planned Structure

```
docker/
├── README.md                       # This file
├── RESEARCH.md                     # Detailed research findings
├── docker-compose.yml              # Production orchestration
├── docker-compose.dev.yml          # Development overrides
├── .env.example                    # Environment variable template
├── Dockerfile.backend              # Backend multi-stage build
├── Dockerfile.frontend             # Frontend multi-stage build
├── Dockerfile.infiniservice        # Infiniservice multi-stage build
├── Dockerfile.libvirt              # Libvirt daemon container
├── scripts/
│   ├── docker-entrypoint-backend.sh
│   ├── docker-entrypoint-frontend.sh
│   ├── docker-entrypoint-infiniservice.sh
│   └── healthcheck.sh
└── config/
    ├── supervisord.conf            # For multi-process libvirt container
    └── nginx.conf                  # Optional reverse proxy
```

## Future Quick Start (Once Implemented)

```bash
# Clone repository
git clone https://github.com/infinibay/infinibay.git
cd infinibay/docker

# Configure environment
cp .env.example .env
# Edit .env with your settings

# Start services
docker-compose up -d

# Access Infinibay
# Frontend: http://localhost:3000
# GraphQL API: http://localhost:4000/graphql
```

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

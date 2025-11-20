# Infinibay Docker Implementation Research

**Date**: 2025-11-20
**Purpose**: Research findings for containerizing Infinibay VDI platform using Docker

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current Infinibay Architecture](#current-infinibay-architecture)
3. [Docker Best Practices for Multi-Service Applications](#docker-best-practices-for-multi-service-applications)
4. [Technical Challenges & Solutions](#technical-challenges--solutions)
5. [Configurable Parameters](#configurable-parameters)
6. [DockerHub Publishing Strategy](#dockerhub-publishing-strategy)
7. [Recommended Architecture](#recommended-architecture)
8. [Implementation Roadmap](#implementation-roadmap)
9. [References](#references)

---

## Executive Summary

Infinibay is a VDI management platform built on multiple services (Node.js backend, Next.js frontend, PostgreSQL, Redis, libvirt/KVM). Containerizing it presents unique challenges due to the need for KVM/libvirt virtualization access from within containers.

### Key Findings:

1. **Multi-stage builds** are essential for both Node.js and Rust components to achieve 70-85% image size reduction
2. **Privileged mode or device passthrough** (`/dev/kvm`) is required for KVM access
3. **Docker Compose** is the recommended orchestration tool for local/development deployments
4. **Process management** requires supervisor/tini instead of systemd within containers
5. **Security** requires proper secrets management (never use ARG/ENV for passwords)

---

## Current Infinibay Architecture

### Components (from installer analysis)

Based on the installer repository analysis, Infinibay consists of:

#### Backend Services
- **Backend**: GraphQL API (Apollo Server 3, Prisma 6, Node.js)
  - Location: `/opt/infinibay/backend`
  - Port: 4000 (configurable)
  - Tech: Node.js + native Rust bindings

- **Frontend**: Web UI (Next.js 14, React 18)
  - Location: `/opt/infinibay/frontend`
  - Port: 3000 (configurable)
  - Tech: Node.js

- **Infiniservice**: Infrastructure orchestration
  - Location: `/opt/infinibay/infiniservice`
  - Port: 9090 (RPC)
  - Tech: Rust (with Windows cross-compilation via mingw-w64)

- **libvirt-node**: Native libvirt bindings
  - Location: `/opt/infinibay/libvirt-node`
  - Tech: Rust + NAPI-RS (Node.js native addon)

#### Infrastructure Dependencies
- **PostgreSQL**: Database (v14+)
  - Default port: 5432
  - Database name: `infinibay`
  - User: `infinibay`

- **Redis**: Firewall rule caching (98% performance improvement)
  - Default port: 6379
  - Graceful degradation if unavailable

- **QEMU/KVM**: Virtualization layer
  - Requires `/dev/kvm` device access

- **libvirt**: VM management daemon
  - Socket: `/var/run/libvirt/libvirt-sock`
  - Network: `default` (configurable)

#### System Dependencies
- Node.js & npm
- Rust & Cargo
- Build tools (gcc, make, pkg-config)
- libvirt-dev, openssl-dev
- btrfs-progs, p7zip (for disk management)
- bridge-utils (for VM networking)

#### Data & Configuration
- **ISOs**: `/opt/infinibay/isos/` (temp + permanent)
- **Disks**: Managed by libvirt storage pools
- **Wallpapers**: `/opt/infinibay/wallpapers/`
- **Sockets**: `/opt/infinibay/sockets/`
- **Environment files**: `.env` in backend and frontend directories

---

## Docker Best Practices for Multi-Service Applications

### 1. Multi-Stage Builds (Critical)

#### Node.js Applications
```dockerfile
# Example pattern (not actual Dockerfile yet)
FROM node:20-alpine AS builder
# Build dependencies
FROM node:20-alpine AS runtime
# Copy only production artifacts
```

**Benefits**:
- 70-85% image size reduction
- Separates build tools from runtime
- Faster deployment (3.5x in benchmarks)
- ~150MB final image for Node.js apps

#### Rust Applications
```dockerfile
# Example pattern
FROM rust:1.75 AS builder
# Compile with cargo
FROM gcr.io/distroless/cc-debian12 AS runtime
# Copy only binary (2GB → 11MB)
```

**Best Practices**:
- Use `cargo-chef` for Docker layer caching (5x faster builds)
- Use distroless images (not Alpine) to avoid libc compatibility issues
- Leverage Rust's built-in cross-compilation for multi-arch builds

### 2. Image Optimization

- **Base images**:
  - Node.js: `node:20-alpine` (smallest)
  - Rust: `gcr.io/distroless/cc-debian12` (security + size)

- **Layer caching**:
  - Copy `package.json`/`Cargo.toml` before source code
  - Place frequently changing files as late as possible

- **Security**:
  - Run as non-root user
  - Multi-stage builds eliminate dev dependencies from final image

### 3. Service Orchestration

#### Docker Compose for Development
- Automatic network creation between services
- Use service names for DNS resolution
- `depends_on` with healthchecks (not just startup)
- Volumes for data persistence

#### Production Considerations
- Kubernetes is the 2025 standard for multi-host clustering
- Docker Swarm does NOT support privileged mode or device passthrough (critical limitation)

### 4. Process Management in Containers

**Do NOT use systemd in containers**. Alternatives:

| Tool | Best For | Notes |
|------|----------|-------|
| **supervisor** | Multi-process containers | Docker-recommended, but doesn't exit on child termination |
| **tini/dumb-init** | PID 1 responsibilities | Built into Docker (`--init` flag), lightweight |
| **s6-overlay** | Complex process trees | Audience favorite, overkill for simple cases |
| **monit** | Daemon-style services | Periodic process checks, complex DSL |

**Recommendation**: Use `tini` (Docker's `--init`) + process-per-container design where possible.

### 5. Secrets Management

**NEVER use ARG or ENV for secrets**. They persist in image layers.

**Recommended approaches**:
- Docker secrets (build-time: `--secret` mount)
- Runtime volumes for sensitive files
- Environment variables ONLY for non-sensitive runtime config
- Integration with HashiCorp Vault or AWS Secrets Manager

**Example**:
```dockerfile
# WRONG - persists in image history
ENV DB_PASSWORD=mypassword

# RIGHT - use secret mount
RUN --mount=type=secret,id=db_password \
    echo "PASSWORD=$(cat /run/secrets/db_password)" > .env
```

---

## Technical Challenges & Solutions

### Challenge 1: KVM/libvirt Access from Docker

**Problem**: Docker containers are isolated from host hardware. KVM requires `/dev/kvm` device access.

**Solutions**:

#### Option A: Privileged Mode (Easier, Less Secure)
```bash
docker run --privileged \
  -v /var/run/libvirt:/var/run/libvirt \
  -v /sys/fs/cgroup:/sys/fs/cgroup \
  infinibay
```

**Pros**: Works with all libvirt features (including macvtap)
**Cons**: Full host access, security risk, not available in Docker Swarm

#### Option B: Device Passthrough (Recommended)
```bash
docker run \
  --device /dev/kvm \
  --device /dev/net/tun \
  -v /var/run/libvirt:/var/run/libvirt \
  --cap-add NET_ADMIN \
  infinibay
```

**Pros**: Narrower attack surface, explicit permissions
**Cons**: May not support all libvirt networking features

**Recommendation**: Start with Option B (device passthrough), fallback to privileged if needed for advanced networking.

### Challenge 2: Multi-Service vs. Microservices

**Current Design**: Infinibay uses separate systemd services per component.

**Container Philosophies**:
1. **One process per container** (Docker best practice)
2. **Multi-process containers** (requires supervisor/init system)

**Recommended Approach**: Hybrid

```yaml
# docker-compose.yml pattern
services:
  postgres:      # Single-process container
  redis:         # Single-process container
  backend:       # Single-process container (Node.js)
  frontend:      # Single-process container (Next.js)
  infiniservice: # Single-process container (Rust)
  libvirt:       # Multi-process (libvirtd + dbus) - use supervisor
```

**Rationale**:
- Database/cache as standard single-service containers
- Application services as single Node.js/Rust processes
- Only libvirt daemon requires multi-process management

### Challenge 3: systemd Services in Installer

**Current Approach**: Installer creates systemd service files for host.

**Docker Alternatives**:

1. **Entrypoint scripts**: Replace systemd service definitions
   ```bash
   #!/bin/bash
   # docker-entrypoint.sh
   cd /app/backend
   exec node dist/index.js
   ```

2. **Docker Compose healthchecks**: Replace systemd service monitoring
   ```yaml
   healthcheck:
     test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
     interval: 30s
     timeout: 10s
     retries: 3
   ```

3. **Restart policies**: Replace systemd auto-restart
   ```yaml
   restart: unless-stopped
   ```

### Challenge 4: Build Complexity

**Components requiring compilation**:
- libvirt-node (Rust → NAPI-RS)
- Backend (npm install + Prisma generate)
- Frontend (Next.js build)
- Infiniservice (Rust → Windows cross-compile)

**Build Order Dependencies** (from installer):
1. libvirt-node (Rust build → npm pack)
2. Backend (depends on libvirt-node package)
3. Frontend (independent)
4. Infiniservice (independent)

**Docker Solution**: Multi-stage builds with build args

```dockerfile
# Stage 1: Build libvirt-node
FROM rust:1.75 AS libvirt-builder
# ... build .tgz package

# Stage 2: Build backend
FROM node:20-alpine AS backend-builder
COPY --from=libvirt-builder /app/libvirt-node.tgz .
# ... npm install

# Stage 3: Runtime
FROM node:20-alpine
COPY --from=backend-builder /app/dist .
```

---

## Configurable Parameters

Based on installer's `args.py` analysis, the following parameters should be configurable via Docker environment variables:

### Database Configuration
| Parameter | Default | Docker ENV | Notes |
|-----------|---------|------------|-------|
| `db-host` | `localhost` | `DB_HOST` | Use service name in Compose |
| `db-port` | `5432` | `DB_PORT` | Standard PostgreSQL |
| `db-name` | `infinibay` | `DB_NAME` | Database name |
| `db-user` | `infinibay` | `DB_USER` | Database user |
| `db-password` | *auto-generated* | `DB_PASSWORD` | **Use Docker secrets** |

### Admin User Configuration
| Parameter | Default | Docker ENV | Notes |
|-----------|---------|------------|-------|
| `admin-email` | `admin@example.com` | `ADMIN_EMAIL` | Initial admin email |
| `admin-password` | `password` | `ADMIN_PASSWORD` | **Use Docker secrets** |

### Network Configuration
| Parameter | Default | Docker ENV | Notes |
|-----------|---------|------------|-------|
| `host-ip` | *auto-detected* | `HOST_IP` | Host IP for VM connectivity |
| `libvirt-network-name` | `default` | `LIBVIRT_NETWORK_NAME` | Virtual network name |
| `backend-port` | `4000` | `BACKEND_PORT` | GraphQL API port |
| `frontend-port` | `3000` | `FRONTEND_PORT` | Web UI port |

### Application Configuration
| Parameter | Default | Docker ENV | Notes |
|-----------|---------|------------|-------|
| `install-dir` | `/opt/infinibay` | `INFINIBAY_BASE_DIR` | Base directory (use volume) |
| `data-dir` | *same as install-dir* | `INFINIBAY_DATA_DIR` | Data volume mount |
| `skip-isos` | `false` | `SKIP_ISO_DOWNLOAD` | Skip ISO downloads |
| `skip-windows-isos` | `false` | `SKIP_WINDOWS_ISO_DOWNLOAD` | Skip Windows ISOs |

### Additional Docker-Specific Parameters

| Parameter | Default | Docker ENV | Purpose |
|-----------|---------|------------|---------|
| - | `4000` | `GRAPHQL_PORT` | Internal GraphQL port |
| - | `9090` | `RPC_PORT` | Infiniservice RPC port |
| - | `localhost` | `REDIS_HOST` | Redis hostname |
| - | `6379` | `REDIS_PORT` | Redis port |
| - | `false` | `REDIS_ENABLED` | Enable/disable Redis caching |
| - | `30000` | `LIBVIRT_CONNECT_TIMEOUT` | Libvirt connection timeout (ms) |
| - | `60000` | `LIBVIRT_OPERATION_TIMEOUT` | Libvirt operation timeout (ms) |

### Volume Mounts Required

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| `/var/run/libvirt` | `/var/run/libvirt` | Libvirt socket communication |
| `infinibay-data` | `/data` | ISOs, disks, wallpapers |
| `infinibay-db` | `/var/lib/postgresql/data` | PostgreSQL persistence |
| `infinibay-redis` | `/data` | Redis persistence (optional) |

---

## DockerHub Publishing Strategy

### 1. Repository Structure

**Recommended naming**:
- `infinibay/infinibay:latest` (all-in-one, if using single image)
- `infinibay/backend:latest`
- `infinibay/frontend:latest`
- `infinibay/infiniservice:latest`

**Tagging strategy**:
- `latest`: Latest stable release
- `v1.2.3`: Semantic versioning
- `dev`: Development/nightly builds
- `v1.2.3-alpine`: Variant tags (if multiple base images)

### 2. Automated Builds (2025 Best Practices)

**Option A: GitHub Actions (Recommended)**

Advantages:
- Free for public repositories
- Tight GitHub integration
- Matrix builds for multi-arch (amd64, arm64)
- Secrets management built-in

**Workflow**:
1. Push to `main` → trigger GitHub Actions
2. Actions build Docker image
3. Actions push to DockerHub using access token
4. Tag releases automatically via `semantic-release`

**Example workflow structure**:
```yaml
# .github/workflows/docker-publish.yml
on:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          token: ${{ secrets.DOCKERHUB_TOKEN }}

      - uses: docker/build-push-action@v4
        with:
          push: true
          tags: infinibay/backend:latest
```

**Option B: GitLab CI**
- Similar automation
- Requires `.gitlab-ci.yml`
- DockerHub push via CI variables

**Option C: DockerHub Autobuild (Legacy)**
- Requires Docker Pro/Team/Business subscription
- Less flexible than GitHub Actions
- Being phased out in favor of CI/CD integrations

### 3. Multi-Architecture Builds

**Challenge**: Infinibay targets x86_64 (common VDI workloads).

**Recommendation**:
- Primary: `linux/amd64`
- Optional: `linux/arm64` (for Apple Silicon dev environments)

**Implementation**: Docker Buildx
```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag infinibay/backend:latest \
  --push .
```

**Note**: Use Rust's native cross-compilation instead of QEMU emulation (5-10x faster).

### 4. Security & Access Tokens

**DO NOT use DockerHub password in CI/CD**. Use access tokens:

1. Generate token: DockerHub → Account Settings → Security → New Access Token
2. Store in GitHub Secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
3. Use in Actions: `docker/login-action@v2`

**Token scopes**: Read & Write (not Delete unless needed)

### 5. Image Size Optimization for DockerHub

**Registry storage costs**: Larger images = higher costs + slower pulls

**Targets** (based on research):
- Node.js services: ~150MB (Alpine + multi-stage)
- Rust services: ~15MB (distroless + multi-stage)
- Total stack: <500MB (excluding PostgreSQL base image)

**Benchmark**: 85% reduction from baseline = 60% storage cost reduction

---

## Recommended Architecture

### Architecture Option 1: Docker Compose (Development/Small Deployments)

**Use case**: Single-host deployments, home labs, small businesses (aligned with Infinibay's target market)

**Structure**:
```
docker/
├── docker-compose.yml          # Main orchestration
├── docker-compose.dev.yml      # Development overrides
├── .env.example                # Template for environment variables
├── Dockerfile.backend          # Backend multi-stage build
├── Dockerfile.frontend         # Frontend multi-stage build
├── Dockerfile.infiniservice    # Infiniservice multi-stage build
├── Dockerfile.libvirt          # Libvirt daemon + supervisor
├── scripts/
│   ├── docker-entrypoint-backend.sh
│   ├── docker-entrypoint-frontend.sh
│   ├── docker-entrypoint-infiniservice.sh
│   └── healthcheck.sh
├── config/
│   ├── supervisord.conf        # For libvirt container
│   └── nginx.conf              # Optional reverse proxy
└── RESEARCH.md                 # This document
```

**Benefits**:
- Simple deployment (`docker-compose up`)
- Matches Infinibay's "simplicity over features" philosophy
- Easy development workflow
- Built-in networking

**Limitations**:
- Single-host only
- Manual scaling

### Architecture Option 2: Kubernetes (Enterprise/Multi-Host)

**Use case**: Cloud deployments, multi-tenant scenarios, high availability

**Structure**:
```
k8s/
├── namespace.yaml
├── postgres-statefulset.yaml
├── redis-deployment.yaml
├── backend-deployment.yaml
├── frontend-deployment.yaml
├── infiniservice-deployment.yaml
├── libvirt-daemonset.yaml      # Runs on each VM host
├── secrets.yaml
└── ingress.yaml
```

**Benefits**:
- Auto-scaling
- High availability
- Load balancing
- Multi-host clustering

**Challenges**:
- KVM device passthrough on each node
- Complexity (contradicts Infinibay's simplicity goal)
- Requires Kubernetes expertise

**Recommendation for v1**: **Start with Docker Compose**. Provide Kubernetes manifests as optional "advanced deployment" later.

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
1. Create multi-stage Dockerfiles for each service
   - ✅ `Dockerfile.libvirt-node` (Rust → NAPI-RS)
   - ✅ `Dockerfile.backend` (Node.js + libvirt-node)
   - ✅ `Dockerfile.frontend` (Next.js)
   - ✅ `Dockerfile.infiniservice` (Rust with Windows cross-compile)

2. Create `docker-compose.yml`
   - PostgreSQL service with volume
   - Redis service with volume
   - Backend service with libvirt access
   - Frontend service
   - Infiniservice RPC service
   - Network configuration

3. Create entrypoint scripts
   - Database migration runner
   - Environment variable validation
   - Healthcheck endpoints

### Phase 2: Configuration & Testing (Week 3)
1. Environment variable mapping
   - Create `.env.example` template
   - Document all configurable parameters
   - Implement fallback defaults

2. Volume management
   - ISO storage volume
   - VM disk storage volume
   - PostgreSQL data volume
   - Redis data volume (optional)

3. Local testing
   - Build images locally
   - Test VM creation workflow
   - Validate libvirt connectivity
   - Performance benchmarks (compare to native)

### Phase 3: CI/CD & Publishing (Week 4)
1. GitHub Actions workflow
   - Matrix builds for multi-arch (if needed)
   - Automated testing in containers
   - Push to DockerHub on tag

2. DockerHub setup
   - Create organization/repositories
   - Configure access tokens
   - Write README.md for Docker Hub

3. Documentation
   - Quick start guide
   - Deployment options (Compose vs manual)
   - Troubleshooting guide
   - Migration guide from installer to Docker

### Phase 4: Optimization (Week 5)
1. Image size optimization
   - Measure current sizes
   - Apply multi-stage build improvements
   - Target: <500MB total stack

2. Build caching
   - Implement cargo-chef for Rust
   - Optimize layer order for Node.js
   - Set up Docker build cache in CI

3. Security hardening
   - Non-root users in containers
   - Secret management documentation
   - Security scanning (Trivy/Snyk)

### Phase 5: Advanced Features (Future)
1. Kubernetes manifests (optional)
2. Helm charts (optional)
3. Docker Swarm configs (skip - no privileged mode support)
4. Monitoring integration (Prometheus/Grafana)

---

## Open Questions & Considerations

### 1. Libvirt Socket Strategy

**Question**: Should libvirt run inside a container or use host's libvirtd?

**Option A**: Libvirt in container
- ✅ Self-contained deployment
- ✅ Version control
- ❌ Requires privileged mode
- ❌ More complex

**Option B**: Use host's libvirt
- ✅ Simpler container setup
- ✅ Leverage existing host libvirt
- ❌ Requires host prerequisites
- ❌ Less portable

**Recommendation**: **Option A** for full Docker deployment, with Option B as "hybrid mode" for users who prefer host libvirt.

### 2. Database Migration Strategy

**Question**: How to handle Prisma migrations on container startup?

**Options**:
1. Run migrations in entrypoint script (automatic)
2. Separate init container in Compose
3. Manual migration command before `docker-compose up`

**Recommendation**: Option 1 (automatic in entrypoint) with flag to disable for production.

### 3. ISO Management

**Question**: How should users provide ISOs to containers?

**Options**:
1. Volume mount from host
2. Download on first startup (current installer behavior)
3. Separate "iso management" container

**Recommendation**: Hybrid - volume mount support + optional download via `SKIP_ISO_DOWNLOAD=false`.

### 4. Windows Cross-Compilation for infiniservice.exe

**Question**: Build Windows executable in Docker or separate workflow?

**Current installer**: Uses `mingw-w64` for Windows builds.

**Recommendation**: Include `mingw64-gcc` in Rust builder stage, but make Windows build optional (Linux-only images are smaller).

### 5. Development vs. Production Images

**Question**: Should we create separate images or use build args?

**Options**:
1. Separate Dockerfiles (`Dockerfile.dev`, `Dockerfile.prod`)
2. Multi-stage with `--target dev|prod`
3. Single image with environment flag

**Recommendation**: Option 2 (multi-stage with targets) for DRY principle.

---

## References

### Docker Best Practices
- [Docker Official Blog: ARG and ENV Best Practices](https://www.docker.com/blog/docker-best-practices-using-arg-and-env-in-your-dockerfiles/)
- [Node.js Docker Optimization 2025](https://markaicode.com/nodejs-docker-optimization-2025/)
- [Rust Docker Multi-Stage Builds](https://dev.to/mattdark/rust-docker-image-optimization-with-multi-stage-builds-4b6c)
- [Multi-Arch Docker Builds for Rust](https://medium.com/@vladkens/fast-multi-arch-docker-build-for-rust-projects-a7db42f3adde)

### KVM/Libvirt in Docker
- [Running Libvirt in Docker (2025)](https://dteslya.engineer/blog/2025/06/06/running-libvirt-host-in-docker/)
- [Stack Overflow: QEMU-KVM in Docker](https://stackoverflow.com/questions/48422001/how-to-launch-qemu-kvm-from-inside-a-docker-container)
- [GitHub: libvirt-docker](https://github.com/substrant/libvirt-docker)

### Docker Compose & Microservices
- [Docker Compose with Node.js, Postgres, Redis](https://medium.com/@loicshyaka09/dockerize-your-node-js-postgres-redis-app-32c203c2d1e9)
- [Microservices Architecture with Docker](https://www.devzero.io/blog/docker-microservices)

### DockerHub Publishing
- [GitHub Actions + DockerHub CI/CD](https://earthly.dev/blog/cicd-build-github-action-dockerhub/)
- [semantic-release for Automated Releases](https://merginit.com/blog/29062025-automated-multi-platform-releases)
- [CircleCI Workflows for Docker](https://circleci.com/blog/using-circleci-workflows-to-replicate-docker-hub-automated-builds/)

### Process Management
- [Choosing an Init Process for Containers](https://ahmet.im/blog/minimal-init-process-for-containers/)
- [Docker Forums: systemd vs supervisor](https://forums.docker.com/t/process-manager-replacement-systemd-supervisor-for-dockerized-software/123696)

### Security
- [Docker Secrets Documentation](https://docs.docker.com/reference/build-checks/secrets-used-in-arg-or-env/)
- [Handling Docker Secrets the Right Way](https://medium.com/@dariusmurawski/handling-docker-secrets-the-right-way-cc625be3395d)

---

## Appendix A: Comparison Matrix

### Container vs. Native Installation

| Aspect | Native Installer | Docker |
|--------|------------------|---------|
| **Installation Time** | ~15-30 min | ~5-10 min (after image pull) |
| **Disk Space** | ~10GB | ~5GB (optimized images) |
| **Dependencies** | System packages | Containerized |
| **Isolation** | None (system-wide) | Full isolation |
| **Portability** | OS-dependent (Ubuntu 23.10+, Fedora 37+) | Any Docker host |
| **Updates** | Re-run installer | Pull new image |
| **Rollback** | Manual | Tag-based rollback |
| **Development** | Full system access | Volume mounts |
| **Performance** | Native | ~5% overhead (negligible) |
| **Complexity** | Moderate (Python installer) | Low (docker-compose up) |

### Deployment Strategies

| Strategy | Best For | Complexity | Scalability |
|----------|----------|------------|-------------|
| **Docker Compose** | Home labs, SMBs | Low | Single-host |
| **Kubernetes** | Enterprises, cloud | High | Multi-host |
| **Docker Swarm** | ❌ Not viable | N/A | No privileged mode |
| **Native Installer** | Traditional servers | Moderate | Manual |

---

## Conclusion

Containerizing Infinibay is feasible and offers significant benefits for deployment simplicity, portability, and consistency. The main technical challenge—KVM/libvirt access—can be solved via device passthrough or privileged mode.

**Recommended first milestone**: Create Docker Compose setup with multi-stage builds, targeting development/small business use cases (aligned with Infinibay's philosophy). Defer Kubernetes to future iterations.

**Next steps**:
1. Create proof-of-concept Dockerfile for backend
2. Test KVM access via `--device /dev/kvm`
3. Build docker-compose.yml for full stack
4. Document deployment process
5. Set up GitHub Actions for automated builds

---

**Document Version**: 1.0
**Last Updated**: 2025-11-20
**Author**: Research Phase (Pre-Implementation)

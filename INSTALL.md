# Infinibay with LXD - Complete Guide

This guide explains how to deploy Infinibay using LXD containers instead of Docker.

## Why LXD Instead of Docker?

**TL;DR**: LXD is better for running libvirt/KVM virtualization inside containers.

| Feature | LXD | Docker |
|---------|-----|--------|
| **KVM Access** | ✅ Native via `unix-char` device | ⚠️ Requires `--privileged` or complex setup |
| **Systemd Support** | ✅ Full systemd inside containers | ❌ Not recommended |
| **Nested Virtualization** | ✅ Designed for it | ⚠️ Limited |
| **Orchestration** | ✅ lxd-compose (YAML) | ✅ docker-compose (YAML) |
| **Security** | ✅ Better isolation for VMs | ⚠️ Privileged mode risky |

**Decision**: LXD is the better choice for Infinibay because we need to run VMs (via libvirt/KVM) inside containers.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  LXD Host (Ubuntu 24.04)                                │
│                                                          │
│  ┌────────────────┐  ┌─────────────────┐               │
│  │ infinibay-     │  │ infinibay-      │               │
│  │ postgres       │  │ redis           │               │
│  │ (Database)     │  │ (Cache)         │               │
│  └────────────────┘  └─────────────────┘               │
│                                                          │
│  ┌──────────────────────────────────────────────┐       │
│  │ infinibay-backend                            │       │
│  │ - Node.js (GraphQL API)                      │       │
│  │ - libvirt-node (Rust native binding)         │       │
│  │ - infiniservice (Rust binary)                │       │
│  │ - Access to /dev/kvm                         │       │
│  │ - Access to /var/run/libvirt                 │       │
│  └──────────────────────────────────────────────┘       │
│                                                          │
│  ┌──────────────────────────────────────────────┐       │
│  │ infinibay-frontend                           │       │
│  │ - Next.js (Web UI)                           │       │
│  └──────────────────────────────────────────────┘       │
│                                                          │
│  Shared: /dev/kvm, /var/run/libvirt                     │
└─────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### System Requirements

- **OS**: Ubuntu 24.04 or later (recommended), Fedora 39+
- **CPU**: x86_64 with VT-x/AMD-V enabled (KVM support)
- **Memory**: Minimum 8GB RAM (16GB+ recommended)
- **Disk**: 50GB+ free space
- **Network**: Static IP or DHCP reservation recommended

### Check KVM Support

```bash
# Check if KVM is available
ls -l /dev/kvm

# Install cpu-checker
sudo apt install cpu-checker

# Verify KVM acceleration
sudo kvm-ok

# Expected output:
# INFO: /dev/kvm exists
# KVM acceleration can be used
```

---

## Installation

### Step 1: Clone Repository

```bash
cd ~
git clone https://github.com/infinibay/infinibay.git
cd infinibay/docker
```

### Step 2: Run Setup Script

The setup script will:
- Install LXD (via snap)
- Install lxd-compose
- Initialize LXD with default configuration
- Create data directories
- Generate `.env` file with secure passwords

```bash
sudo ./setup.sh
```

**Output**:
```
==============================================
  Infinibay LXD Setup
==============================================

[INFO] Checking KVM support...
[SUCCESS] KVM acceleration available
[INFO] Installing LXD via snap...
[SUCCESS] LXD installed successfully
[INFO] Initializing LXD...
[SUCCESS] LXD initialized
[INFO] Installing lxd-compose...
[SUCCESS] lxd-compose installed
[INFO] Creating data directories...
[SUCCESS] Data directories created
[INFO] Copying .env.example to .env...
[INFO] Auto-detected host IP: 192.168.1.100
[SUCCESS] Generated secure passwords in .env file
[WARNING] IMPORTANT: Review and customize .env before deployment!
```

### Step 3: Configure Environment

Edit the `.env` file with your settings:

```bash
nano .env
```

**Important variables to check**:

```bash
# Database password (auto-generated, but you can change it)
DB_PASSWORD=your_secure_password_here

# Admin credentials (CHANGE THESE!)
ADMIN_EMAIL=admin@yourdomain.com
ADMIN_PASSWORD=your_admin_password

# Host IP (auto-detected, verify it's correct)
HOST_IP=192.168.1.100

# Libvirt network (default is usually fine)
LIBVIRT_NETWORK_NAME=default
```

### Step 4: Deploy Containers

```bash
# Make sure you're in the docker/ directory
cd ~/infinibay/docker

# Deploy all containers
lxd-compose apply
```

**What happens**:
1. Creates LXD project `infinibay`
2. Creates network `infinibay-net`
3. Launches 4 containers:
   - `infinibay-postgres` (Database)
   - `infinibay-redis` (Cache)
   - `infinibay-backend` (API + libvirt)
   - `infinibay-frontend` (Web UI)
4. Runs cloud-init to install dependencies and build applications
5. Starts services via systemd inside containers

**This process takes 10-15 minutes** (building Rust components).

### Step 5: Verify Deployment

```bash
# List all containers
lxc list

# Expected output:
# +---------------------+---------+----------------------+------+-----------+
# | NAME                | STATE   | IPV4                 | TYPE | SNAPSHOTS |
# +---------------------+---------+----------------------+------+-----------+
# | infinibay-backend   | RUNNING | 10.10.10.10 (eth0)   | CONTAINER | 0  |
# | infinibay-frontend  | RUNNING | 10.10.10.11 (eth0)   | CONTAINER | 0  |
# | infinibay-postgres  | RUNNING | 10.10.10.12 (eth0)   | CONTAINER | 0  |
# | infinibay-redis     | RUNNING | 10.10.10.13 (eth0)   | CONTAINER | 0  |
# +---------------------+---------+----------------------+------+-----------+

# Check backend logs
lxc exec infinibay-backend -- journalctl -u infinibay-backend -n 50

# Check frontend logs
lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -n 50

# Test database connection
lxc exec infinibay-postgres -- su - postgres -c "psql -c 'SELECT version();'"

# Test Redis
lxc exec infinibay-redis -- redis-cli ping
# Expected: PONG
```

### Step 6: Access Infinibay

Open your browser:

- **Frontend**: `http://<HOST_IP>:3000`
- **GraphQL API**: `http://<HOST_IP>:4000/graphql`

**Default credentials** (from `.env`):
- Email: `admin@example.com` (or what you set in `.env`)
- Password: Your `ADMIN_PASSWORD` from `.env`

---

## Common Operations

### Start/Stop Containers

```bash
# Stop all Infinibay containers
lxd-compose destroy

# Start all containers
lxd-compose apply

# Restart a specific container
lxc restart infinibay-backend
```

### View Logs

```bash
# Backend logs (real-time)
lxc exec infinibay-backend -- journalctl -u infinibay-backend -f

# Frontend logs
lxc exec infinibay-frontend -- journalctl -u infinibay-frontend -f

# PostgreSQL logs
lxc exec infinibay-postgres -- tail -f /var/log/postgresql/postgresql-14-main.log

# All system logs from a container
lxc exec infinibay-backend -- journalctl -f
```

### Execute Commands Inside Containers

```bash
# Open shell in backend container
lxc exec infinibay-backend -- bash

# Run npm command in backend
lxc exec infinibay-backend -- su - infinibay -c "cd /opt/infinibay/backend && npm run db:migrate"

# Check Node.js version
lxc exec infinibay-backend -- node --version

# Check Rust version
lxc exec infinibay-backend -- cargo --version
```

### Database Operations

```bash
# Access PostgreSQL shell
lxc exec infinibay-postgres -- su - postgres -c "psql infinibay"

# Backup database
lxc exec infinibay-postgres -- su - postgres -c "pg_dump infinibay" > infinibay-backup.sql

# Restore database
cat infinibay-backup.sql | lxc exec infinibay-postgres -- su - postgres -c "psql infinibay"

# Run migrations
lxc exec infinibay-backend -- su - infinibay -c "cd /opt/infinibay/backend && npx prisma migrate deploy"
```

### Update Application Code

```bash
# Pull latest code in backend
lxc exec infinibay-backend -- bash -c "cd /opt/infinibay/backend && git pull && npm install && systemctl restart infinibay-backend"

# Pull latest code in frontend
lxc exec infinibay-frontend -- bash -c "cd /opt/infinibay/frontend && git pull && npm install && npm run build && systemctl restart infinibay-frontend"
```

### Resource Monitoring

```bash
# Show resource usage
lxc list --format table --columns ns4tDcm

# Detailed info for a container
lxc info infinibay-backend

# Monitor CPU/Memory usage
watch -n 1 'lxc list --format table --columns ns4tDcm'
```

---

## Troubleshooting

### Container Won't Start

```bash
# Check container status
lxc list

# View container logs
lxc info infinibay-backend --show-log

# Start manually and watch logs
lxc start infinibay-backend
lxc exec infinibay-backend -- journalctl -f
```

### KVM Not Working

```bash
# Check if /dev/kvm is accessible inside container
lxc exec infinibay-backend -- ls -l /dev/kvm

# Expected output:
# crw-rw---- 1 root kvm 10, 232 Nov 20 17:00 /dev/kvm

# Check if libvirt socket is mounted
lxc exec infinibay-backend -- ls -l /var/run/libvirt/

# Test libvirt connection
lxc exec infinibay-backend -- virsh -c qemu:///system list --all
```

### Database Connection Issues

```bash
# Test PostgreSQL is running
lxc exec infinibay-postgres -- systemctl status postgresql

# Test connection from backend
lxc exec infinibay-backend -- psql -h infinibay-postgres -U infinibay -d infinibay -c "SELECT 1;"

# Check PostgreSQL logs
lxc exec infinibay-postgres -- tail -f /var/log/postgresql/postgresql-14-main.log
```

### Network Issues Between Containers

```bash
# Test network connectivity
lxc exec infinibay-backend -- ping -c 3 infinibay-postgres
lxc exec infinibay-backend -- ping -c 3 infinibay-redis

# Check DNS resolution
lxc exec infinibay-backend -- nslookup infinibay-postgres

# Check open ports
lxc exec infinibay-postgres -- ss -tlnp | grep 5432
lxc exec infinibay-redis -- ss -tlnp | grep 6379
```

### Reset Everything

```bash
# Stop and delete all containers
lxd-compose destroy
lxc delete infinibay-backend infinibay-frontend infinibay-postgres infinibay-redis --force

# Delete project
lxc project delete infinibay

# Delete data (WARNING: DELETES ALL DATA)
sudo rm -rf /var/lib/infinibay/

# Start fresh
./setup.sh
lxd-compose apply
```

---

## Advanced Configuration

### Custom LXD Profiles

You can create custom profiles for specific needs:

```bash
# Create a high-performance profile
lxc profile create infinibay-highperf

# Edit profile
lxc profile edit infinibay-highperf
```

```yaml
config:
  limits.cpu: "8"
  limits.memory: "16GB"
  limits.memory.swap: "false"
devices:
  kvm:
    type: unix-char
    path: /dev/kvm
  root:
    type: disk
    path: /
    pool: default
    size: 100GB
```

### Storage Optimization

```bash
# Create a dedicated storage pool for PostgreSQL (faster I/O)
lxc storage create infinibay-db btrfs size=100GB

# Migrate postgres data to new pool
lxc storage volume create infinibay-db postgres-data
lxc config device add infinibay-postgres postgres-data disk source=postgres-data pool=infinibay-db path=/var/lib/postgresql/data
```

### Network Customization

```bash
# Create a custom bridge with specific subnet
lxc network create infinibay-bridge \
  ipv4.address=192.168.100.1/24 \
  ipv4.nat=true \
  ipv6.address=none

# Attach container to custom bridge
lxc config device override infinibay-backend eth0 parent=infinibay-bridge
```

### Snapshots and Backups

```bash
# Create snapshot before updates
lxc snapshot infinibay-backend backup-$(date +%Y%m%d)

# List snapshots
lxc info infinibay-backend

# Restore from snapshot
lxc restore infinibay-backend backup-20251120

# Export container as backup
lxc export infinibay-backend infinibay-backend-backup.tar.gz

# Import backup
lxc import infinibay-backend-backup.tar.gz
```

---

## Performance Tuning

### CPU Pinning

```bash
# Pin backend to specific CPU cores (0-3)
lxc config set infinibay-backend limits.cpu 0-3
```

### I/O Priority

```bash
# Set I/O priority for database
lxc config set infinibay-postgres limits.disk.priority 10
```

### Disable Unnecessary Services

Inside backend container:

```bash
lxc exec infinibay-backend -- bash

# Disable snapd (if not needed)
systemctl disable snapd
systemctl stop snapd

# Disable unattended-upgrades during production
systemctl disable unattended-upgrades
```

---

## Migration from Native Installation

If you have Infinibay installed natively via the installer:

### Step 1: Backup Data

```bash
# Backup database
sudo -u postgres pg_dump infinibay > infinibay-backup.sql

# Backup ISOs and data
sudo tar -czf infinibay-data-backup.tar.gz /opt/infinibay/isos /opt/infinibay/wallpapers
```

### Step 2: Stop Native Services

```bash
sudo systemctl stop infinibay-backend infinibay-frontend
sudo systemctl disable infinibay-backend infinibay-frontend
```

### Step 3: Deploy LXD Version

```bash
cd ~/infinibay/docker
sudo ./setup.sh
lxd-compose apply
```

### Step 4: Restore Data

```bash
# Restore database
cat infinibay-backup.sql | lxc exec infinibay-postgres -- su - postgres -c "psql infinibay"

# Restore data files
tar -xzf infinibay-data-backup.tar.gz -C /var/lib/infinibay/data/
```

---

## Comparison: LXD vs Native Installer

| Aspect | LXD | Native Installer |
|--------|-----|------------------|
| **Installation Time** | ~15 min | ~20-30 min |
| **Isolation** | ✅ Full container isolation | ❌ System-wide |
| **Updates** | ✅ Container snapshots | ⚠️ Re-run installer |
| **Rollback** | ✅ Instant (snapshots) | ❌ Manual |
| **Resource Usage** | ~5% overhead | Native performance |
| **Complexity** | Medium (LXD knowledge) | Low (automated script) |
| **Portability** | ✅ Export/import containers | ❌ Tied to host |
| **Multi-host** | ✅ LXD clustering | ❌ Manual setup |

---

## FAQ

### Q: Can I use Docker instead of LXD?

**A**: Yes, but you'll need privileged mode for KVM access, which is less secure. See `RESEARCH.md` for Docker approach.

### Q: Can I run multiple Infinibay instances?

**A**: Yes! Use different LXD projects:

```bash
# Create second instance
lxc project create infinibay-dev
lxc project switch infinibay-dev
# Edit lxd-compose.yml to use different ports
lxd-compose apply
```

### Q: How do I upgrade LXD?

```bash
snap refresh lxd
```

### Q: Can I access containers from other machines?

```bash
# Expose LXD API
lxc config set core.https_address "[::]:8443"

# Set trust password
lxc config set core.trust_password "your-password"

# From remote machine:
lxc remote add infinibay-host https://<HOST_IP>:8443
```

### Q: What's the difference between LXC and LXD?

**LXC**: Low-level container runtime (like runc for Docker)
**LXD**: High-level management daemon (like Docker daemon)

You interact with LXD using the `lxc` command (confusingly named!).

---

## Resources

- **LXD Documentation**: https://documentation.ubuntu.com/lxd/
- **lxd-compose**: https://mottainaici.github.io/lxd-compose-docs/
- **Infinibay Research**: See `RESEARCH.md` in this directory
- **Community Forum**: https://discuss.linuxcontainers.org/

---

## License

Same as Infinibay project (MIT License).

**Last Updated**: 2025-11-20
**Version**: 1.0.0

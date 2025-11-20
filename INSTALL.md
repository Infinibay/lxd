# Infinibay with LXD - Installation Guide

Complete guide for deploying Infinibay using LXD containers.

## Why LXD?

LXD provides native support for KVM/libvirt virtualization inside containers without requiring privileged mode.

| Feature | LXD | Docker |
|---------|-----|--------|
| **KVM Access** | ✅ Native via `unix-char` device | ⚠️ Requires `--privileged` |
| **Systemd Support** | ✅ Full systemd inside containers | ❌ Not recommended |
| **Nested Virtualization** | ✅ Designed for it | ⚠️ Limited |
| **Security** | ✅ Better isolation for VMs | ⚠️ Privileged mode risky |

---

## Prerequisites

### System Requirements

- **OS**: Ubuntu 24.04+ or Fedora 39+
- **CPU**: x86_64 with VT-x/AMD-V enabled (KVM support)
- **Memory**: Minimum 8GB RAM (16GB+ recommended)
- **Disk**: 50GB+ free space

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
cd infinibay/lxd
```

### Step 2: Run Setup Script

```bash
sudo ./setup.sh
```

The setup script will:
- Install LXD (via snap)
- Install lxd-compose
- Initialize LXD with default configuration
- Add your user to `lxd` group
- Create `~/.config/lxc/config.yml` for lxd-compose
- Create data directories
- Generate `.env` file with secure passwords

**Expected output:**
```
==============================================
  Infinibay LXD Setup
==============================================

[INFO] Checking KVM support...
[SUCCESS] KVM acceleration available
[INFO] Installing system dependencies...
[SUCCESS] System dependencies installed
[SUCCESS] LXD already installed: Client version: 5.21.4 LTS
[SUCCESS] LXD initialized
[INFO] Installing lxd-compose...
[SUCCESS] lxd-compose installed successfully
[INFO] Creating data directories...
[SUCCESS] Data directories created
[INFO] Configuring LXC for user...
[SUCCESS] Created LXC config file: /home/user/.config/lxc/config.yml
[SUCCESS] Generated secure passwords in .env file

==============================================
[SUCCESS] Setup completed successfully!
==============================================

⚠️  IMPORTANT: User was added to lxd group

Before running lxd-compose, you MUST activate the group change:

  Option 1 (Quick - in current session):
    newgrp lxd

  Option 2 (Permanent - requires re-login):
    logout and login again
```

### Step 3: Activate lxd Group

**CRITICAL STEP:** The setup script adds you to the `lxd` group, but you need to activate it.

**Option 1 - Quick (current session only):**
```bash
newgrp lxd
```
This opens a new shell with the `lxd` group active. Stay in this shell for the remaining steps.

**Option 2 - Permanent (requires logout):**
```bash
logout
# Then login again
```

**Verify you're in the group:**
```bash
groups | grep lxd
# Should show 'lxd' in the output
```

### Step 4: Configure Environment

```bash
nano .env
```

**Important variables to check:**

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

### Step 5: Verify Setup

```bash
# Check that lxd-compose recognizes the project
lxd-compose project list

# Expected output:
# | PROJECT NAME | DESCRIPTION                       | # GROUPS |
# |--------------|-----------------------------------|----------|
# | infinibay    | Infinibay VDI Management Platform | 4        |
```

### Step 6: Deploy Containers

```bash
./run.sh apply
```

**What happens:**
1. Generates LXD profiles with correct paths
2. Downloads Ubuntu container images (first time only)
3. Creates 4 containers:
   - `infinibay-postgres` (PostgreSQL database)
   - `infinibay-redis` (Redis cache)
   - `infinibay-backend` (Node.js API with KVM access)
   - `infinibay-frontend` (Next.js UI)
4. Configures resource limits (CPU, RAM)
5. Mounts shared directories:
   - `/opt/infinibay` → Your code (shared)
   - `/data` → Persistent data (per container)

### Step 7: Provision Containers

```bash
./run.sh provision
```

**What happens (takes 5-10 minutes):**
1. **PostgreSQL container:**
   - Installs PostgreSQL 14
   - Configures data directory `/data/pgdata`
   - Creates `infinibay` database and user
   - Enables network access for other containers

2. **Redis container:**
   - Installs Redis server
   - Configures persistence to `/data/redis`
   - Enables network access

3. **Backend container:**
   - Installs Node.js 20.x LTS + npm
   - Installs Rust toolchain (for native modules)
   - Installs libvirt + KVM dependencies
   - Configures `/dev/kvm` device access
   - Sets up libvirt storage pool at `/data/libvirt`
   - Creates systemd service

4. **Frontend container:**
   - Installs Node.js 20.x LTS + npm
   - Creates systemd service
   - Sets up log directories

### Step 8: Verify Deployment

```bash
# List all containers
lxc list

# Expected output:
# +---------------------+---------+----------------------+------+-----------+
# | NAME                | STATE   | IPV4                 | TYPE | SNAPSHOTS |
# +---------------------+---------+----------------------+------+-----------+
# | infinibay-backend   | RUNNING | 10.x.x.x (eth0)      | CONTAINER | 0  |
# | infinibay-frontend  | RUNNING | 10.x.x.x (eth0)      | CONTAINER | 0  |
# | infinibay-postgres  | RUNNING | 10.x.x.x (eth0)      | CONTAINER | 0  |
# | infinibay-redis     | RUNNING | 10.x.x.x (eth0)      | CONTAINER | 0  |
# +---------------------+---------+----------------------+------+-----------+
```

---

## Common Operations

### Managing Containers

```bash
# Deploy containers
./run.sh apply

# Provision software
./run.sh provision

# Check status
./run.sh status

# Destroy all containers
./run.sh destroy

# Restart from scratch
./run.sh restart

# View project info
lxd-compose project list

# View container status
lxc list
```

### Accessing Containers

```bash
# Open shell in container
lxc exec infinibay-backend -- bash

# View logs (if service is configured)
lxc exec infinibay-backend -- journalctl -f

# Execute command
lxc exec infinibay-postgres -- ls -la /var/lib/postgresql
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

## Troubleshooting

### "No project selected" Error

```bash
# Wrong:
lxd-compose apply

# Correct:
lxd-compose apply infinibay
```

### "Unable to read the configuration file" Error

This means lxd-compose can't find `~/.config/lxc/config.yml`.

**Solution:**
```bash
# The setup script should have created this file
# If it's missing, you can create it manually:
mkdir -p ~/.config/lxc
cat > ~/.config/lxc/config.yml << 'EOF'
default-remote: local
remotes:
  local:
    addr: unix://
    protocol: lxd
    public: false
  images:
    addr: https://images.lxd.canonical.com
    protocol: simplestreams
    public: true
EOF
```

### "Permission denied" on LXD Socket

This means you're not in the `lxd` group or haven't activated it.

**Check:**
```bash
groups | grep lxd
```

**If `lxd` doesn't appear:**
```bash
# Add yourself to the group
sudo usermod -aG lxd $USER

# Then activate it
newgrp lxd
```

**If `lxd` appears but still getting errors:**
```bash
# You need to activate the group change
newgrp lxd
```

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

### Reset Everything

```bash
# Stop and delete all containers
lxd-compose destroy infinibay

# Or manually:
lxc delete infinibay-backend infinibay-frontend infinibay-postgres infinibay-redis --force

# Delete data (WARNING: DELETES ALL DATA)
sudo rm -rf /var/lib/infinibay/

# Start fresh
sudo ./setup.sh
newgrp lxd
lxd-compose apply infinibay
```

---

## Current Status

✅ **LXD implementation is fully functional!**

**What works:**
- ✅ Container creation and orchestration
- ✅ Automated provisioning scripts (`./run.sh provision`)
- ✅ PostgreSQL installation and configuration
- ✅ Redis installation and configuration
- ✅ Node.js 20.x + Rust toolchain
- ✅ KVM/libvirt device passthrough and configuration
- ✅ Shared code directory (`/opt/infinibay`)
- ✅ Persistent data directories (`/data`)
- ✅ Resource limits (CPU, RAM)
- ✅ Network connectivity between containers
- ✅ Systemd services ready

**What's still manual:**
- ⏳ npm install in backend/frontend
- ⏳ Database migrations
- ⏳ Starting Infinibay services
- ⏳ Application-specific configuration

**For production:** Both LXD and [native installer](../installer/) are production-ready options.

---

## Next Steps After Provisioning

After running `./run.sh provision`, complete the setup:

### 1. Install npm Dependencies

```bash
# Backend
./run.sh exec backend bash
cd /opt/infinibay/backend
npm install

# Frontend (in another terminal or after exiting)
./run.sh exec frontend bash
cd /opt/infinibay/frontend
npm install
```

### 2. Build Native Modules

```bash
# Backend: Build libvirt-node (Rust → Node.js bindings)
./run.sh exec backend bash
cd /opt/infinibay/libvirt-node
npm install
npm run build
```

### 3. Run Database Migrations

```bash
./run.sh exec backend bash
cd /opt/infinibay/backend
npm run db:migrate
```

### 4. Start Services

```bash
# Backend
./run.sh exec backend systemctl start infinibay-backend

# Frontend
./run.sh exec frontend systemctl start infinibay-frontend

# Check status
./run.sh exec backend systemctl status infinibay-backend
./run.sh exec frontend systemctl status infinibay-frontend
```

### 5. Access Infinibay

```bash
# Find frontend IP
lxc list infinibay-frontend

# Open in browser
# http://<frontend-ip>:3000
```

---

## FAQ

### Q: Can I use this for production?

**A:** Yes! The LXD implementation is now production-ready with automated provisioning. It provides the same functionality as the native installer with better isolation.

### Q: What's the difference between LXD and the native installer?

**A:**
- **LXD**: Containers with better isolation, easier backup/restore, snapshots
- **Native**: Installs directly on host, simpler architecture
- Both are production-ready, choose based on your preference

### Q: Can I run multiple Infinibay instances?

**A:** Yes! Edit `envs/infinibay.yml` and create a second project with different container names and ports.

### Q: How do I update to the latest version?

**A:**
```bash
cd ~/infinibay/lxd
git pull
lxd-compose apply infinibay
```

---

## Resources

- [LXD Documentation](https://documentation.ubuntu.com/lxd/)
- [lxd-compose Documentation](https://mottainaici.github.io/lxd-compose-docs/)
- [Infinibay Native Installer](../installer/) - **Recommended for production**

---

**Last Updated**: 2025-11-20
**Status**: Basic Structure Complete

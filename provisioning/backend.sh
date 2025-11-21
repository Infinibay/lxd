#!/bin/bash
# Backend Provisioning Script for Infinibay
# This script installs Node.js, Rust, libvirt and sets up the backend API

set -e

echo "=== Backend Provisioning ==="

# Update package lists
apt-get update

# Install system dependencies
echo "Installing system dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
    libvirt-dev \
    libvirt-daemon-system \
    libvirt-clients \
    qemu-kvm \
    qemu-utils \
    bridge-utils \
    python3 \
    python3-pip

# Clone Infinibay repositories
echo "Cloning Infinibay repositories..."
mkdir -p /opt/infinibay
chmod 755 /opt/infinibay

# Configure git to trust Infinibay directories
git config --global --add safe.directory /opt/infinibay/backend
git config --global --add safe.directory /opt/infinibay/libvirt-node
git config --global --add safe.directory /opt/infinibay/installer

# Clone backend
if [ ! -d /opt/infinibay/backend/.git ]; then
    echo "Cloning backend repository..."
    git clone https://github.com/Infinibay/backend.git /opt/infinibay/backend
    chmod -R 755 /opt/infinibay/backend
else
    echo "Backend repository already exists, pulling latest changes..."
    cd /opt/infinibay/backend && git pull
fi

# Clone libvirt-node (required for backend)
if [ ! -d /opt/infinibay/libvirt-node/.git ]; then
    echo "Cloning libvirt-node repository..."
    git clone https://github.com/Infinibay/libvirt-node.git /opt/infinibay/libvirt-node
    chmod -R 755 /opt/infinibay/libvirt-node
else
    echo "libvirt-node repository already exists, pulling latest changes..."
    cd /opt/infinibay/libvirt-node && git pull
fi

# Clone installer (for scripts and utilities)
if [ ! -d /opt/infinibay/installer/.git ]; then
    echo "Cloning installer repository..."
    git clone https://github.com/Infinibay/installer.git /opt/infinibay/installer
    chmod -R 755 /opt/infinibay/installer
else
    echo "installer repository already exists, pulling latest changes..."
    cd /opt/infinibay/installer && git pull
fi

echo "✓ Repositories cloned successfully"

# Install Node.js 20.x (LTS)
echo "Installing Node.js 20.x..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

# Verify Node.js installation
node --version
npm --version

# Create infinibay user if it doesn't exist
if ! id -u infinibay > /dev/null 2>&1; then
    useradd -m -s /bin/bash infinibay
    # Add infinibay user to libvirt and kvm groups
    usermod -aG libvirt infinibay
    usermod -aG kvm infinibay
fi

# Install Rust for building native modules
echo "Installing Rust..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Make Rust available for infinibay user
if [ ! -d /home/infinibay/.cargo ]; then
    su - infinibay -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
fi

# Verify Rust installation
su - infinibay -c "source ~/.cargo/env && rustc --version"

# Configure libvirt
echo "Configuring libvirt..."
systemctl enable libvirtd
systemctl start libvirtd

# Configure libvirt to use /data for images
# Create subdirectories for libvirt
mkdir -p /data/libvirt/images /data/libvirt/networks
chown -R libvirt-qemu:kvm /data/libvirt
chmod 755 /data/libvirt

# Update libvirt pool configuration
virsh pool-destroy default 2>/dev/null || true
virsh pool-undefine default 2>/dev/null || true

# Create new default pool pointing to /data
cat > /tmp/pool.xml << 'EOF'
<pool type='dir'>
  <name>default</name>
  <target>
    <path>/data/libvirt/images</path>
  </target>
</pool>
EOF

virsh pool-define /tmp/pool.xml
virsh pool-start default
virsh pool-autostart default
rm /tmp/pool.xml

# Verify KVM access
echo "Verifying KVM access..."
ls -la /dev/kvm
if [ -c /dev/kvm ]; then
    echo "✓ KVM device available"
    chmod 666 /dev/kvm  # Allow access (already should be via group)
else
    echo "⚠ WARNING: /dev/kvm not available"
fi

# Set up directories
# Note: /data permissions already fixed earlier for libvirt
mkdir -p /data/logs /data/uploads /data/tmp
chown -R infinibay:infinibay /data/logs /data/uploads /data/tmp

# Set up wallpapers directory
echo "Setting up wallpapers directory..."
mkdir -p /opt/infinibay/wallpapers
chmod 755 /opt/infinibay/wallpapers
echo "✓ Wallpapers directory created"

# Create systemd service for backend
cat > /etc/systemd/system/infinibay-backend.service << 'EOF'
[Unit]
Description=Infinibay Backend API
After=network.target postgresql.service redis.service libvirtd.service
Wants=postgresql.service redis.service libvirtd.service

[Service]
Type=simple
User=infinibay
WorkingDirectory=/opt/infinibay/backend
Environment=NODE_ENV=production
Environment=PORT=4000
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=10
StandardOutput=append:/data/logs/backend.log
StandardError=append:/data/logs/backend-error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Create backend environment configuration
echo "Creating backend .env file..."

# Verify backend directory exists and is writable
if [ ! -d /opt/infinibay/backend ]; then
    echo "✗ ERROR: /opt/infinibay/backend directory does not exist!"
    exit 1
fi

# Ensure directory is writable
chmod 755 /opt/infinibay/backend
echo "Backend directory permissions: $(ls -ld /opt/infinibay/backend)"

# Use environment variables set by LXD-compose, with fallback defaults
DB_NAME=${DB_NAME:-infinibay}
DB_USER=${DB_USER:-infinibay}
DB_PASSWORD=${DB_PASSWORD:-changeme}
HOST_IP=${HOST_IP:-192.168.0.1}
LIBVIRT_NETWORK_NAME=${LIBVIRT_NETWORK_NAME:-default}
TOKENKEY=${TOKENKEY:-changeme}

# Create backend .env with LXD container networking
cat > /opt/infinibay/backend/.env << EOF
# Database Configuration (using LXD container name)
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@infinibay-postgres:5432/${DB_NAME}?schema=public

# Redis Configuration (using LXD container name)
REDIS_URL=redis://infinibay-redis:6379

# Application Configuration
NODE_ENV=production
PORT=4000
TOKENKEY=${TOKENKEY}
BCRYPT_ROUNDS=10
FRONTEND_URL=*

# Network Configuration
APP_HOST=${HOST_IP}
GRAPHIC_HOST=${HOST_IP}

# Directory Configuration
INFINIBAY_BASE_DIR=/opt/infinibay
INFINIBAY_ISO_DIR=/opt/infinibay/iso
INFINIBAY_ISO_TEMP_DIR=/opt/infinibay/iso/temp
INFINIBAY_ISO_PERMANENT_DIR=/opt/infinibay/iso/permanent
INFINIBAY_STORAGE_POOL_NAME=infinibay
INFINIBAY_WALLPAPERS_DIR=/opt/infinibay/wallpapers

# Libvirt Configuration
LIBVIRT_NETWORK_NAME=${LIBVIRT_NETWORK_NAME}

# RPC Configuration
RPC_URL=http://localhost:9090
EOF

# Set proper ownership and permissions
chown infinibay:infinibay /opt/infinibay/backend/.env
chmod 600 /opt/infinibay/backend/.env
echo "✓ Backend .env file created"

# Build libvirt-node BEFORE installing backend dependencies
echo "Building libvirt-node native module (this may take a few minutes)..."

# Change ownership to infinibay user so they can build
chown -R infinibay:infinibay /opt/infinibay/libvirt-node

# Install dependencies and build as infinibay user
su - infinibay -c "cd /opt/infinibay/libvirt-node && npm install"
su - infinibay -c "source ~/.cargo/env && cd /opt/infinibay/libvirt-node && npm run build"

# Verify the build succeeded
if ls /opt/infinibay/libvirt-node/libvirt*.node 1> /dev/null 2>&1; then
    echo "✓ libvirt-node native module built successfully:"
    ls -lh /opt/infinibay/libvirt-node/libvirt*.node
else
    echo "✗ ERROR: libvirt-node native module build failed - .node file not found"
    exit 1
fi

# Package libvirt-node for backend consumption
echo "Packaging libvirt-node..."
cd /opt/infinibay/libvirt-node && npm pack
TARBALL=$(ls /opt/infinibay/libvirt-node/infinibay-libvirt-node-*.tgz 2>/dev/null)
if [ -z "$TARBALL" ]; then
    echo "✗ ERROR: Failed to create libvirt-node tarball"
    exit 1
fi

# Create lib directory in backend and move tarball
mkdir -p /opt/infinibay/backend/lib/libvirt-node
cp "$TARBALL" /opt/infinibay/backend/lib/libvirt-node/infinibay-libvirt-node-0.0.1.tgz
echo "✓ libvirt-node packaged and ready for backend"

# Install backend npm dependencies
echo "Installing backend dependencies..."

# Change ownership to infinibay user
chown -R infinibay:infinibay /opt/infinibay/backend

# Remove package-lock.json to avoid integrity checksum conflicts with libvirt-node tarball
# The checksum in package-lock.json is from an old build, but we just created a fresh tarball
if [ -f /opt/infinibay/backend/package-lock.json ]; then
    echo "Removing old package-lock.json to regenerate with fresh libvirt-node tarball..."
    rm /opt/infinibay/backend/package-lock.json
fi

# Install as infinibay user (will regenerate package-lock.json)
# Note: We need devDependencies to build TypeScript
su - infinibay -c "cd /opt/infinibay/backend && npm install"

PACKAGE_COUNT=$(cd /opt/infinibay/backend && npm list --depth=0 2>/dev/null | grep -c "├\|└" || echo "unknown")
echo "✓ Backend dependencies installed ($PACKAGE_COUNT packages)"

# Build TypeScript to JavaScript
echo "Building backend (compiling TypeScript)..."
su - infinibay -c "cd /opt/infinibay/backend && npm run build"
if [ $? -eq 0 ]; then
    echo "✓ Backend built successfully"
    ls -lh /opt/infinibay/backend/dist/index.js
else
    echo "✗ ERROR: Backend build failed"
    exit 1
fi

# Generate Prisma Client
echo "Generating Prisma Client..."
cd /opt/infinibay/backend && npx prisma generate
if [ $? -eq 0 ]; then
    echo "✓ Prisma Client generated successfully"
else
    echo "✗ ERROR: Prisma Client generation failed"
    echo "   Please verify:"
    echo "   - Prisma CLI is installed: ls /opt/infinibay/backend/node_modules/.bin/prisma"
    echo "   - Schema file exists and is valid: cat /opt/infinibay/backend/prisma/schema.prisma"
    echo "   - DATABASE_URL is set in /opt/infinibay/backend/.env"
    echo "   - Try running manually: cd /opt/infinibay/backend && npx prisma generate"
    exit 1
fi

# Run database migrations
echo "Running database migrations..."
echo "Database URL: postgresql://${DB_USER}:****@infinibay-postgres:5432/${DB_NAME}"

# Ensure DATABASE_URL is available for Prisma commands
export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@infinibay-postgres:5432/${DB_NAME}?schema=public"

# Try migrate deploy first (production migrations)
cd /opt/infinibay/backend
if npx prisma migrate deploy; then
    echo "✓ Database migrations applied successfully"
else
    echo "⚠ No migrations found or migrate deploy failed, falling back to db push..."

    # Check if database is empty before using db push --accept-data-loss
    echo "Checking if database is empty..."
    TABLE_COUNT=$(lxc exec infinibay-postgres -- su - postgres -c "psql -d ${DB_NAME} -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';\"" 2>/dev/null | tr -d '[:space:]' || echo "error")

    if [ "$TABLE_COUNT" = "error" ]; then
        echo "✗ ERROR: Could not check database state"
        echo "   Please verify PostgreSQL connection and try again"
        exit 1
    elif [ "$TABLE_COUNT" -gt 0 ]; then
        echo "✗ ERROR: migrate deploy failed on a non-empty database"
        echo "   Database contains $TABLE_COUNT table(s) - refusing to run db push with --accept-data-loss"
        echo "   Please resolve migration issues manually:"
        echo "   1. Check migration files in backend/prisma/migrations/"
        echo "   2. Verify schema.prisma matches database state"
        echo "   3. Run 'npx prisma migrate resolve' if needed"
        echo "   4. Or manually run 'npx prisma migrate deploy' from backend directory"
        exit 1
    else
        echo "✓ Database is empty, safe to use db push"
        # Fallback to db push (pushes schema directly without migrations)
        if npx prisma db push --accept-data-loss; then
            echo "✓ Database schema pushed successfully"
        else
            echo "✗ ERROR: Database migration failed"
            echo "   Please verify:"
            echo "   - PostgreSQL is running: lxc exec infinibay-postgres -- systemctl status postgresql"
            echo "   - Database is accessible: lxc exec infinibay-postgres -- su - postgres -c 'psql -c \"SELECT 1\"'"
            echo "   - DATABASE_URL is correct in /opt/infinibay/backend/.env"
            exit 1
        fi
    fi
fi

# Verify database connection
echo "Verifying database connection..."
if npx prisma db execute --stdin <<< "SELECT 1;" > /dev/null 2>&1; then
    echo "✓ Database connection verified"
else
    echo "⚠ WARNING: Could not verify database connection (this may be normal if prisma db execute is not available)"
fi

# Run database seed
echo "Running database seed..."
cd /opt/infinibay/backend
if su - infinibay -c "cd /opt/infinibay/backend && npm run db:seed"; then
    echo "✓ Database seeded successfully"
else
    echo "⚠ WARNING: Database seed failed (this may be normal if seed script doesn't exist or database is already seeded)"
    echo "   You can run it manually later: cd /opt/infinibay/backend && npm run db:seed"
fi

# ============================================================================
# Service Startup
# ============================================================================

echo "Starting infinibay-backend service..."

# Enable service to start on boot
systemctl enable infinibay-backend

# Start the service
systemctl start infinibay-backend

# Wait for service to become active (30 second timeout)
echo "Waiting for backend service to start..."
SERVICE_STARTED=false
for i in {1..30}; do
    if systemctl is-active --quiet infinibay-backend; then
        echo "✓ Backend service is running"
        SERVICE_STARTED=true
        break
    fi
    sleep 1
done

if [ "$SERVICE_STARTED" = false ]; then
    echo "⚠ WARNING: Backend service did not start within 30 seconds"
    echo "   Check service status manually: systemctl status infinibay-backend"
fi

# Display service status for debugging
echo ""
echo "Service status:"
systemctl status infinibay-backend --no-pager || true

echo ""
echo "Backend provisioning completed!"
echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"
echo "Rust version: $(su - infinibay -c 'source ~/.cargo/env && rustc --version')"
echo "Libvirt version: $(virsh --version)"
echo ""
echo "KVM status:"
kvm-ok 2>/dev/null || echo "kvm-ok not available, checking manually..."
[ -c /dev/kvm ] && echo "✓ /dev/kvm is accessible" || echo "✗ /dev/kvm not accessible"
echo ""
echo "Libvirt storage pool:"
virsh pool-list
echo ""
echo "Service has been started and enabled to run on boot."
echo ""
echo "Logs: /data/logs/backend.log"

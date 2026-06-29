#!/bin/bash
# Backend Provisioning Script for Infinibay
# This script installs Node.js, QEMU, infinization and sets up the backend API

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the universal package manager library
source "${SCRIPT_DIR}/../lib/package-manager.sh"

echo "=== Backend Provisioning ==="

# Update package lists
pkg_update

# Install system dependencies
echo "Installing system dependencies..."
pkg_install \
    curl \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
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
git config --global --add safe.directory /opt/infinibay/infinization
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

# Clone infinization (required for backend)
if [ ! -d /opt/infinibay/infinization/.git ]; then
    echo "Cloning infinization repository..."
    git clone https://github.com/Infinibay/infinization.git /opt/infinibay/infinization
    chmod -R 755 /opt/infinibay/infinization
else
    echo "infinization repository already exists, pulling latest changes..."
    cd /opt/infinibay/infinization && git pull
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
install_nodejs

# Verify Node.js installation
node --version
npm --version

# Create infinibay user if it doesn't exist
if ! id -u infinibay > /dev/null 2>&1; then
    useradd -m -s /bin/bash infinibay
    # Add infinibay user to kvm group
    usermod -aG kvm infinibay
fi

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
# Note: /data permissions configured for infinibay user
mkdir -p /data/logs /data/uploads /data/tmp
chown -R infinibay:infinibay /data/logs /data/uploads /data/tmp

# Set up wallpapers directory
echo "Setting up wallpapers directory..."
mkdir -p /opt/infinibay/wallpapers
chmod 755 /opt/infinibay/wallpapers
echo "✓ Wallpapers directory created"

# Create systemd service for backend
cat > /etc/systemd/system/infinibay-backend.service << EOF
[Unit]
Description=Infinibay Backend API
After=network.target postgresql.service redis.service
Wants=postgresql.service redis.service

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
TOKENKEY=${TOKENKEY:-changeme}
INFINISERVICE_HMAC_MASTER_SECRET=${INFINISERVICE_HMAC_MASTER_SECRET:-changeme}

# Create backend .env with LXD container networking
cat > /opt/infinibay/backend/.env << EOF
# Database Configuration (using LXD container name)
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@infinibay-postgres:5432/${DB_NAME}?schema=public

# Application Configuration
NODE_ENV=production
PORT=4000
TOKENKEY=${TOKENKEY}
# Master secret for signing commands to the in-guest infiniservice agent
# (per-VM key = HMAC(this, vmId)); unset => agent rejects all commands.
INFINISERVICE_HMAC_MASTER_SECRET=${INFINISERVICE_HMAC_MASTER_SECRET}
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
INFINIBAY_WALLPAPERS_DIR=/opt/infinibay/wallpapers

# RPC Configuration
RPC_URL=http://localhost:9090
EOF

# Set proper ownership and permissions
chown infinibay:infinibay /opt/infinibay/backend/.env
chmod 600 /opt/infinibay/backend/.env
echo "✓ Backend .env file created"

# Build infinization BEFORE installing backend dependencies
echo "Building infinization (this may take a few minutes)..."

# Change ownership to infinibay user so they can build
chown -R infinibay:infinibay /opt/infinibay/infinization

# Install dependencies and build as infinibay user
echo "Installing infinization dependencies..."
su - infinibay -c "cd /opt/infinibay/infinization && npm install"

echo "Compiling infinization TypeScript..."
su - infinibay -c "cd /opt/infinibay/infinization && npm run build"

# Verify the build succeeded
if [ -f /opt/infinibay/infinization/dist/index.js ]; then
    echo "✓ infinization built successfully:"
    ls -lh /opt/infinibay/infinization/dist/index.js
else
    echo "✗ ERROR: infinization build failed - dist/index.js not found"
    exit 1
fi

# Install nftables systemd service
echo "Installing infinization nftables service..."
cd /opt/infinibay/infinization/systemd
./install-service.sh

if systemctl is-enabled infinization-nftables.service > /dev/null 2>&1; then
    echo "✓ infinization-nftables service installed and enabled"
else
    echo "✗ ERROR: Failed to install infinization-nftables service"
    exit 1
fi

echo "✓ infinization installation complete"

# Install backend npm dependencies
echo "Installing backend dependencies..."

# Change ownership to infinibay user
chown -R infinibay:infinibay /opt/infinibay/backend

# Install as infinibay user
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
echo ""
echo "KVM status:"
kvm-ok 2>/dev/null || echo "kvm-ok not available, checking manually..."
[ -c /dev/kvm ] && echo "✓ /dev/kvm is accessible" || echo "✗ /dev/kvm not accessible"
echo ""
echo "Infinization status:"
systemctl status infinization-nftables.service --no-pager || echo "infinization-nftables service not started (will start on boot)"
echo ""
echo "Service has been started and enabled to run on boot."
echo ""
echo "Logs: /data/logs/backend.log"

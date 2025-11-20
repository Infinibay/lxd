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
mkdir -p /data/libvirt/images
mkdir -p /data/libvirt/networks
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
mkdir -p /data/logs
mkdir -p /data/uploads
mkdir -p /data/tmp
chown -R infinibay:infinibay /data

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
ExecStart=/usr/bin/npm run start
Restart=always
RestartSec=10
StandardOutput=append:/data/logs/backend.log
StandardError=append:/data/logs/backend-error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

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
echo "To start the backend:"
echo "  1. cd /opt/infinibay/backend"
echo "  2. npm install (if not done)"
echo "  3. npm run db:migrate"
echo "  4. systemctl start infinibay-backend"
echo ""
echo "Logs: /data/logs/backend.log"

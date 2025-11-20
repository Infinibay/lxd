#!/bin/bash
# Frontend Provisioning Script for Infinibay
# This script installs Node.js and sets up the Next.js frontend

set -e

echo "=== Frontend Provisioning ==="

# Update package lists
apt-get update

# Install dependencies
echo "Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    git \
    build-essential

# Install Node.js 20.x (LTS)
echo "Installing Node.js 20.x..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

# Verify installation
node --version
npm --version

# Create infinibay user if it doesn't exist
if ! id -u infinibay > /dev/null 2>&1; then
    useradd -m -s /bin/bash infinibay
fi

# Set up directories
mkdir -p /data/logs
mkdir -p /data/cache
chown -R infinibay:infinibay /data

# Install PM2 for process management
echo "Installing PM2..."
npm install -g pm2

# Create PM2 startup script
cat > /usr/local/bin/infinibay-frontend << 'EOF'
#!/bin/bash
cd /opt/infinibay/frontend
exec su - infinibay -c "cd /opt/infinibay/frontend && npm run dev"
EOF

chmod +x /usr/local/bin/infinibay-frontend

# Create systemd service
cat > /etc/systemd/system/infinibay-frontend.service << 'EOF'
[Unit]
Description=Infinibay Frontend (Next.js)
After=network.target

[Service]
Type=simple
User=infinibay
WorkingDirectory=/opt/infinibay/frontend
Environment=NODE_ENV=production
Environment=PORT=3000
ExecStart=/usr/bin/npm run start
Restart=always
RestartSec=10
StandardOutput=append:/data/logs/frontend.log
StandardError=append:/data/logs/frontend-error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "Frontend provisioning completed!"
echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"
echo ""
echo "To start the frontend:"
echo "  1. cd /opt/infinibay/frontend"
echo "  2. npm install (if not done)"
echo "  3. npm run build"
echo "  4. systemctl start infinibay-frontend"
echo ""
echo "Logs: /data/logs/frontend.log"

#!/bin/bash
# Redis Provisioning Script for Infinibay
# This script installs and configures Redis inside the container

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the universal package manager library
source "${SCRIPT_DIR}/../lib/package-manager.sh"

echo "=== Redis Provisioning ==="

# Update package lists
pkg_update

# Install Redis
echo "Installing Redis..."
pkg_install redis

# Get Redis service name and config path
REDIS_SERVICE=$(get_service_name redis)
REDIS_CONF=$(get_config_path redis)

# Stop Redis to reconfigure
systemctl stop "$REDIS_SERVICE"

# Configure Redis to use /data
echo "Configuring Redis..."
# Create subdirectory for Redis data
mkdir -p /data/redis
chown redis:redis /data/redis
chmod 750 /data/redis

# Backup original config
cp "$REDIS_CONF" "${REDIS_CONF}.backup"

# Update Redis configuration
cat > "$REDIS_CONF" << 'EOF'
# Infinibay Redis Configuration

# Network
bind 0.0.0.0
protected-mode no
port 6379
timeout 0
tcp-keepalive 300

# General
daemonize no
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log

# Persistence - use /data directory
dir /data/redis
dbfilename dump.rdb
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes

# Snapshotting
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# Memory management
maxmemory-policy allkeys-lru

# Clients
maxclients 10000
EOF

# Start Redis
systemctl start "$REDIS_SERVICE"
systemctl enable "$REDIS_SERVICE"

# Wait for Redis to be ready
sleep 2

# Test Redis
redis-cli ping

echo "Redis provisioning completed!"
echo "Redis is listening on: 0.0.0.0:6379"
echo "Data directory: /data/redis"
echo "Log file: /var/log/redis/redis-server.log"

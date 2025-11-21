#!/bin/bash
# Redis Provisioning Script for Infinibay
# This script installs and configures Redis inside the container

set -e

echo "=== Redis Provisioning ==="

# Update package lists
apt-get update

# Install Redis
echo "Installing Redis..."
DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server

# Stop Redis to reconfigure
systemctl stop redis-server

# Configure Redis to use /data
echo "Configuring Redis..."
# Create subdirectory for Redis data
mkdir -p /data/redis
chown redis:redis /data/redis
chmod 750 /data/redis

# Backup original config
cp /etc/redis/redis.conf /etc/redis/redis.conf.backup

# Update Redis configuration
cat > /etc/redis/redis.conf << 'EOF'
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
systemctl start redis-server
systemctl enable redis-server

# Wait for Redis to be ready
sleep 2

# Test Redis
redis-cli ping

echo "Redis provisioning completed!"
echo "Redis is listening on: 0.0.0.0:6379"
echo "Data directory: /data/redis"
echo "Log file: /var/log/redis/redis-server.log"

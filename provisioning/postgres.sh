#!/bin/bash
# PostgreSQL Provisioning Script for Infinibay
# This script installs and configures PostgreSQL inside the container

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the universal package manager library
source "${SCRIPT_DIR}/../lib/package-manager.sh"

echo "=== PostgreSQL Provisioning ==="

# Update package lists
pkg_update

# Install PostgreSQL
echo "Installing PostgreSQL..."
pkg_install postgresql postgresql-contrib

# Initialize PostgreSQL (distribution-specific)
init_postgresql

# Get PostgreSQL service name
PG_SERVICE=$(get_service_name postgresql)

# Stop PostgreSQL to reconfigure
systemctl stop "$PG_SERVICE"

# Get PostgreSQL version
PG_VERSION=$(ls /etc/postgresql/)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

# Configure PostgreSQL to use /data
echo "Configuring data directory..."
# Create subdirectory for PostgreSQL data
mkdir -p /data/pgdata
chown -R postgres:postgres /data/pgdata
chmod 700 /data/pgdata

# Initialize data directory if empty
if [ ! -f /data/pgdata/PG_VERSION ]; then
    echo "Initializing PostgreSQL data directory..."
    su - postgres -c "/usr/lib/postgresql/$PG_VERSION/bin/initdb -D /data/pgdata"
fi

# Update postgresql.conf
sed -i "s|data_directory = .*|data_directory = '/data/pgdata'|" "$PG_CONF"
sed -i "s|#listen_addresses = 'localhost'|listen_addresses = '*'|" "$PG_CONF"

# Configure authentication to allow connections from other containers
echo "Configuring authentication..."
cat >> "$PG_HBA" << 'EOF'

# Allow connections from Infinibay containers
host    all             all             10.0.0.0/8              scram-sha-256
host    all             all             172.16.0.0/12           scram-sha-256
EOF

# Start PostgreSQL
systemctl start "$PG_SERVICE"
systemctl enable "$PG_SERVICE"

# Wait for PostgreSQL to be ready
sleep 3

# Create Infinibay database and user (if they don't exist)
echo "Creating Infinibay database and user..."

# Create user only if it doesn't exist
su - postgres -c "psql -tc \"SELECT 1 FROM pg_user WHERE usename = 'infinibay'\" | grep -q 1" || \
    su - postgres -c "psql -c \"CREATE USER infinibay WITH PASSWORD 'changeme';\""

# Create database only if it doesn't exist
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname = 'infinibay'\" | grep -q 1" || \
    su - postgres -c "psql -c \"CREATE DATABASE infinibay OWNER infinibay;\""

# Grant privileges (safe to run even if already granted)
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE infinibay TO infinibay;\""

echo "PostgreSQL provisioning completed!"
echo "Database: infinibay"
echo "User: infinibay"
echo "Password: changeme (CHANGE THIS!)"
echo "Data directory: /data/pgdata"

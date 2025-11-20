#!/bin/bash
# PostgreSQL Provisioning Script for Infinibay
# This script installs and configures PostgreSQL inside the container

set -e

echo "=== PostgreSQL Provisioning ==="

# Update package lists
apt-get update

# Install PostgreSQL
echo "Installing PostgreSQL..."
DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib

# Stop PostgreSQL to reconfigure
systemctl stop postgresql

# Get PostgreSQL version
PG_VERSION=$(ls /etc/postgresql/)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

# Configure PostgreSQL to use /data
echo "Configuring data directory..."
# Fix /data permissions (mounted from host as nobody:nogroup)
chmod 777 /data
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
systemctl start postgresql
systemctl enable postgresql

# Wait for PostgreSQL to be ready
sleep 3

# Create Infinibay database and user
echo "Creating Infinibay database and user..."
su - postgres -c "psql -c \"CREATE USER infinibay WITH PASSWORD 'changeme';\""
su - postgres -c "psql -c \"CREATE DATABASE infinibay OWNER infinibay;\""
su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE infinibay TO infinibay;\""

echo "PostgreSQL provisioning completed!"
echo "Database: infinibay"
echo "User: infinibay"
echo "Password: changeme (CHANGE THIS!)"
echo "Data directory: /data/pgdata"

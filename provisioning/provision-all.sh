#!/bin/bash
# Master provisioning script for all Infinibay containers
# This script orchestrates provisioning of all containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Health check failure tracking
HEALTH_FAILED=false

echo -e "${BLUE}=== Infinibay Container Provisioning ===${NC}"
echo ""

# Function to provision a container
provision_container() {
    local container=$1
    local script=$2
    shift 2
    local env_vars="$@"

    echo -e "${BLUE}Provisioning ${container}...${NC}"

    # Copy script to container
    lxc file push "$SCRIPT_DIR/$script" "$container/tmp/provision.sh"

    # Make it executable and run it with environment variables
    lxc exec "$container" -- chmod +x /tmp/provision.sh
    if [ -n "$env_vars" ]; then
        lxc exec "$container" -- env $env_vars /tmp/provision.sh
    else
        lxc exec "$container" -- /tmp/provision.sh
    fi

    # Clean up
    lxc exec "$container" -- rm /tmp/provision.sh

    echo -e "${GREEN}✓ ${container} provisioned successfully${NC}"
    echo ""
}

# Check if containers are running
echo "Checking container status..."
if ! lxc list | grep -q "infinibay-postgres.*RUNNING"; then
    echo -e "${RED}Error: Containers are not running${NC}"
    echo "Run './run.sh apply' first"
    exit 1
fi

echo -e "${GREEN}All containers are running${NC}"
echo ""

# Provision in order (database first, then cache, then services)
echo -e "${YELLOW}Step 1/4: Provisioning PostgreSQL...${NC}"
provision_container "infinibay-postgres" "postgres.sh"

echo -e "${YELLOW}Step 2/4: Provisioning Redis...${NC}"
provision_container "infinibay-redis" "redis.sh"

echo -e "${YELLOW}Step 3/4: Provisioning Backend...${NC}"
provision_container "infinibay-backend" "backend.sh"

echo -e "${YELLOW}Step 4/4: Provisioning Frontend...${NC}"
# Detect HOST IP (not container IP) since ports are proxied to host
# Get the IP of the default route interface (usually the main network interface)
HOST_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K[\d.]+')
if [ -z "$HOST_IP" ]; then
    echo -e "${YELLOW}Warning: Could not detect host IP, trying alternative method${NC}"
    HOST_IP=$(hostname -I | awk '{print $1}')
fi
if [ -z "$HOST_IP" ]; then
    echo -e "${RED}Error: Could not detect host IP${NC}"
    exit 1
fi
echo -e "${GREEN}Detected host IP: ${HOST_IP}${NC}"
echo -e "${BLUE}Backend will be accessible at: http://${HOST_IP}:4000${NC}"
provision_container "infinibay-frontend" "frontend.sh" "BACKEND_IP=$HOST_IP"

echo ""
echo -e "${BLUE}=== Verifying Services ===${NC}"
echo ""

# PostgreSQL Health Check
if lxc exec infinibay-postgres -- su - postgres -c "psql -c 'SELECT 1'" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ PostgreSQL is responding${NC}"
else
    echo -e "${RED}✗ PostgreSQL is not responding${NC}"
    HEALTH_FAILED=true
fi

# Redis Health Check
if lxc exec infinibay-redis -- redis-cli ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Redis is responding${NC}"
else
    echo -e "${RED}✗ Redis is not responding${NC}"
    HEALTH_FAILED=true
fi

# Backend Service Health Check
if lxc exec infinibay-backend -- systemctl is-active --quiet infinibay-backend; then
    echo -e "${GREEN}✓ Backend service is running${NC}"
else
    echo -e "${RED}✗ Backend service is not running${NC}"
    HEALTH_FAILED=true
fi

# Frontend Service Health Check
if lxc exec infinibay-frontend -- systemctl is-active --quiet infinibay-frontend; then
    echo -e "${GREEN}✓ Frontend service is running${NC}"
else
    echo -e "${RED}✗ Frontend service is not running${NC}"
    HEALTH_FAILED=true
fi

echo ""
if [ "$HEALTH_FAILED" = false ]; then
    echo -e "${GREEN}=== Infinibay is ready! ===${NC}"
    echo ""
    echo -e "Access the web interface at: ${BLUE}http://localhost:3000${NC}"
    echo -e "Backend API endpoint: ${BLUE}http://localhost:4000/graphql${NC}"
    echo ""
else
    echo -e "${YELLOW}=== Provisioning completed with errors ===${NC}"
    echo ""
    echo -e "${YELLOW}Some services failed health checks. Please review the errors above.${NC}"
    echo ""
    echo -e "If services are running, you can access:"
    echo -e "  Web interface: ${BLUE}http://localhost:3000${NC}"
    echo -e "  Backend API: ${BLUE}http://localhost:4000/graphql${NC}"
    echo ""
    exit 1
fi

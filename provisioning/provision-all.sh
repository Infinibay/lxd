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

echo -e "${BLUE}=== Infinibay Container Provisioning ===${NC}"
echo ""

# Function to provision a container
provision_container() {
    local container=$1
    local script=$2

    echo -e "${BLUE}Provisioning ${container}...${NC}"

    # Copy script to container
    lxc file push "$SCRIPT_DIR/$script" "$container/tmp/provision.sh"

    # Make it executable and run it
    lxc exec "$container" -- chmod +x /tmp/provision.sh
    lxc exec "$container" -- /tmp/provision.sh

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
provision_container "infinibay-frontend" "frontend.sh"

echo ""
echo -e "${GREEN}=== Provisioning Complete! ===${NC}"
echo ""
echo "Container Status:"
lxc list | grep infinibay
echo ""
echo "Next steps:"
echo "  1. Update database password in values.yml"
echo "  2. Install npm dependencies:"
echo "     ./run.sh exec backend bash -c 'cd /opt/infinibay/backend && npm install'"
echo "     ./run.sh exec frontend bash -c 'cd /opt/infinibay/frontend && npm install'"
echo "  3. Run database migrations:"
echo "     ./run.sh exec backend bash -c 'cd /opt/infinibay/backend && npm run db:migrate'"
echo "  4. Start services:"
echo "     ./run.sh exec backend systemctl start infinibay-backend"
echo "     ./run.sh exec frontend systemctl start infinibay-frontend"

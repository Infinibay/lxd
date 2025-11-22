#!/bin/bash
# Provisioning State Management Library
# Uses LXD's user.* config namespace for persistent state tracking

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Mark a container as successfully provisioned
# Usage: mark_provisioned <container-name>
mark_provisioned() {
    local container=$1

    if [ -z "$container" ]; then
        echo -e "${RED}Error: mark_provisioned requires a container name${NC}" >&2
        return 1
    fi

    # Set provisioning marker (assumes script runs with proper lxd group permissions)
    if lxc config set "$container" user.provisioned true 2>/dev/null; then
        echo -e "${GREEN}✓ Marked $container as provisioned${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to mark $container as provisioned${NC}" >&2
        return 1
    fi
}

# Check if a container is provisioned
# Returns 0 (success) if provisioned, 1 (failure) otherwise
# Usage: is_provisioned <container-name>
is_provisioned() {
    local container=$1

    if [ -z "$container" ]; then
        echo -e "${RED}Error: is_provisioned requires a container name${NC}" >&2
        return 1
    fi

    # Get provisioning marker (assumes script runs with proper lxd group permissions)
    local value=$(lxc config get "$container" user.provisioned 2>/dev/null || echo "")

    if [ "$value" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# Clear provisioning marker from a container
# Used when destroying/recreating containers or forcing re-provisioning
# Usage: clear_provisioned <container-name>
clear_provisioned() {
    local container=$1

    if [ -z "$container" ]; then
        echo -e "${RED}Error: clear_provisioned requires a container name${NC}" >&2
        return 1
    fi

    # Clear provisioning marker (assumes script runs with proper lxd group permissions)
    if lxc config unset "$container" user.provisioned 2>/dev/null; then
        echo -e "${YELLOW}Cleared provisioning marker for $container${NC}"
        return 0
    else
        # Unsetting a non-existent key is not an error
        return 0
    fi
}

# Get human-readable provisioning status for display
# Returns: "Provisioned", "Not Provisioned", or "Unknown"
# Usage: get_provisioning_status <container-name>
get_provisioning_status() {
    local container=$1

    if [ -z "$container" ]; then
        echo "Unknown"
        return 1
    fi

    # Check if container exists (assumes script runs with proper lxd group permissions)
    if ! lxc info "$container" >/dev/null 2>&1; then
        echo "Unknown"
        return 1
    fi

    # Check provisioning state
    if is_provisioned "$container"; then
        echo "Provisioned"
    else
        echo "Not Provisioned"
    fi
}

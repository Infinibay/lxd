#!/bin/bash
# Infinibay LXD Management Script
# Handles profile generation and container lifecycle

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get absolute path to infinibay directory (parent of lxd/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFINIBAY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}Infinibay Directory: ${INFINIBAY_DIR}${NC}"

# Check if values.yml exists
if [[ ! -f "$SCRIPT_DIR/values.yml" ]]; then
    echo -e "${YELLOW}Warning: values.yml not found${NC}"
    echo -e "Copy values.yml.example to values.yml and customize it:"
    echo -e "   ${BLUE}cp values.yml.example values.yml${NC}"
    echo -e "   ${BLUE}nano values.yml${NC}"
    exit 1
fi

# Function to generate profile from template
generate_profile() {
    local template_file="$1"
    local output_file="$2"

    sed "s|{{INFINIBAY_DIR}}|${INFINIBAY_DIR}|g" "$template_file" > "$output_file"
}

# Function to create/update LXD profiles
setup_profiles() {
    echo -e "${BLUE}Setting up LXD profiles...${NC}"

    # Create profiles directory if it doesn't exist
    mkdir -p "$SCRIPT_DIR/profiles/generated"

    # Generate profiles from templates
    for template in "$SCRIPT_DIR/profiles/templates"/*.yml; do
        local profile_name=$(basename "$template" .yml)
        local output_file="$SCRIPT_DIR/profiles/generated/${profile_name}.yml"

        echo -e "  Generating ${profile_name}..."
        generate_profile "$template" "$output_file"

        # Create or update profile in LXD
        if sg lxd -c "lxc profile show '$profile_name'" >/dev/null 2>&1; then
            echo -e "  Updating ${profile_name}..."
            sg lxd -c "cat '$output_file' | lxc profile edit '$profile_name'"
        else
            echo -e "  Creating ${profile_name}..."
            sg lxd -c "lxc profile create '$profile_name'"
            sg lxd -c "cat '$output_file' | lxc profile edit '$profile_name'"
        fi
    done

    echo -e "${GREEN}Profiles configured successfully!${NC}"
}

# Function to ensure data directories exist
ensure_data_dirs() {
    echo -e "${BLUE}Ensuring data directories exist...${NC}"
    mkdir -p "$INFINIBAY_DIR/data"/{postgres,redis,backend,frontend}
    # Set permissions so containers can write to these directories
    # LXD uses user namespaces, so we need to make directories writable
    chmod 777 "$INFINIBAY_DIR/data"/{postgres,redis,backend,frontend}
    echo -e "${GREEN}Data directories ready${NC}"
}

# Main command handler
case "${1:-apply}" in
    setup-profiles)
        echo -e "${BLUE}=== Setting up profiles ===${NC}"
        setup_profiles
        ;;

    apply)
        echo -e "${BLUE}=== Applying Infinibay configuration ===${NC}"
        ensure_data_dirs
        setup_profiles
        echo -e "${BLUE}Starting containers...${NC}"
        cd "$SCRIPT_DIR"
        sg lxd -c "LXD_DIR=/var/snap/lxd/common/lxd lxd-compose apply infinibay"
        echo -e "${GREEN}Infinibay containers are running!${NC}"
        echo -e "\nTo check status: ${BLUE}lxc list${NC}"
        ;;

    destroy)
        echo -e "${YELLOW}=== Destroying Infinibay containers ===${NC}"
        cd "$SCRIPT_DIR"
        sg lxd -c "LXD_DIR=/var/snap/lxd/common/lxd lxd-compose destroy infinibay"
        echo -e "${GREEN}Containers destroyed${NC}"
        ;;

    restart)
        echo -e "${BLUE}=== Restarting Infinibay ===${NC}"
        "$0" destroy
        "$0" apply
        ;;

    provision)
        echo -e "${BLUE}=== Provisioning Infinibay Containers ===${NC}"
        if [[ ! -f "$SCRIPT_DIR/provisioning/provision-all.sh" ]]; then
            echo -e "${RED}Error: provisioning/provision-all.sh not found${NC}"
            exit 1
        fi
        sg lxd -c "$SCRIPT_DIR/provisioning/provision-all.sh"
        ;;

    status)
        echo -e "${BLUE}=== Infinibay Status ===${NC}"
        sg lxd -c "lxc list" | grep infinibay || echo "No Infinibay containers running"
        ;;

    exec)
        if [[ -z "$2" ]]; then
            echo -e "${RED}Usage: $0 exec <container-name> [command]${NC}"
            echo -e "Example: $0 exec backend bash"
            exit 1
        fi
        container="infinibay-$2"
        shift 2
        cmd="${*:-bash}"
        sg lxd -c "lxc exec '$container' -- $cmd"
        ;;

    logs)
        if [[ -z "$2" ]]; then
            echo -e "${RED}Usage: $0 logs <container-name>${NC}"
            exit 1
        fi
        sg lxd -c "lxc exec 'infinibay-$2' -- journalctl -f"
        ;;

    help|--help|-h)
        echo -e "${BLUE}Infinibay LXD Management Script${NC}"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  apply           - Create/start all containers (default)"
        echo "  provision       - Install software in all containers"
        echo "  destroy         - Stop and remove all containers"
        echo "  restart         - Destroy and recreate all containers"
        echo "  status          - Show container status"
        echo "  setup-profiles  - Generate and update LXD profiles only"
        echo "  exec <name> [cmd] - Execute command in container"
        echo "                      (e.g., exec backend bash)"
        echo "  logs <name>     - Follow logs from container"
        echo "  help            - Show this help"
        echo ""
        echo "Examples:"
        echo "  $0 apply              # Start Infinibay"
        echo "  $0 provision          # Install PostgreSQL, Redis, Node.js, etc."
        echo "  $0 status             # Check if running"
        echo "  $0 exec backend bash  # Enter backend container"
        echo "  $0 logs postgres      # View postgres logs"
        echo "  $0 destroy            # Stop everything"
        ;;

    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo -e "Run ${BLUE}$0 help${NC} for usage information"
        exit 1
        ;;
esac

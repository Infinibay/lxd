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
source "$SCRIPT_DIR/lib/lxd-path.sh"
source "$SCRIPT_DIR/lib/provisioning-state.sh"

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

# Helper function to check if infinibay environment exists
# Verifies that all four expected containers exist
check_environment_exists() {
    local containers=("infinibay-postgres" "infinibay-redis" "infinibay-backend" "infinibay-frontend")
    set +e
    local all_exist=0

    for container in "${containers[@]}"; do
        sg lxd -c "lxc info '$container'" >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            all_exist=1
            break
        fi
    done

    set -e
    return $all_exist
}

# Helper function to check if all containers are running
check_containers_running() {
    local containers=("infinibay-postgres" "infinibay-redis" "infinibay-backend" "infinibay-frontend")
    set +e
    local all_running=0

    for container in "${containers[@]}"; do
        local state=$(sg lxd -c "lxc list '$container' --format=csv -c s" 2>/dev/null)
        if [[ "$state" != "RUNNING" ]]; then
            all_running=1
            break
        fi
    done

    set -e
    return $all_running
}

# Helper function to check if containers are provisioned
# Uses LXD metadata-based provisioning state tracking
check_provisioned() {
    local containers=("infinibay-postgres" "infinibay-redis" "infinibay-backend" "infinibay-frontend")
    set +e
    local all_provisioned=0

    for container in "${containers[@]}"; do
        if ! is_provisioned "$container"; then
            all_provisioned=1
            break
        fi
    done

    set -e
    return $all_provisioned
}

# Helper function to ensure containers are running
ensure_containers_running() {
    local containers=("infinibay-postgres" "infinibay-redis" "infinibay-backend" "infinibay-frontend")
    local has_missing=0

    echo -e "${BLUE}Checking container states...${NC}"
    for container in "${containers[@]}"; do
        set +e
        local state=$(sg lxd -c "lxc info '$container' 2>/dev/null" | grep "Status:" | awk '{print $2}')
        set -e

        if [[ -z "$state" ]]; then
            echo -e "  ${RED}Warning: $container does not exist or status cannot be determined${NC}"
            has_missing=1
        elif [[ "$state" == "Stopped" ]] || [[ "$state" == "STOPPED" ]]; then
            echo -e "  ${YELLOW}Starting $container...${NC}"
            sg lxd -c "lxc start '$container'"
        elif [[ "$state" == "Running" ]] || [[ "$state" == "RUNNING" ]]; then
            echo -e "  ${GREEN}$container is already running${NC}"
        else
            echo -e "  ${RED}Warning: $container has unrecognized state: $state${NC}"
            has_missing=1
        fi
    done

    return $has_missing
}

# Smart default function - orchestrates apply → provision → start
smart_default() {
    echo -e "${BLUE}=== Running intelligent environment setup ===${NC}\n"

    # Check if environment exists
    if ! check_environment_exists; then
        echo -e "${YELLOW}Environment does not exist. Creating fresh environment...${NC}"
        ensure_data_dirs
        setup_profiles
        echo -e "${BLUE}Starting containers...${NC}"
        cd "$SCRIPT_DIR"
        sg lxd -c "LXD_DIR=$LXD_DIR lxd-compose apply infinibay"
    else
        echo -e "${GREEN}Environment exists${NC}"
    fi

    # Ensure containers are running
    if ! check_containers_running; then
        echo -e "${YELLOW}Some containers are stopped. Starting them...${NC}"
        if ! ensure_containers_running; then
            echo -e "${RED}Error: Some containers are missing or have unrecognized states${NC}"
            echo -e "${YELLOW}Run with 'redo' to destroy and recreate the complete environment${NC}"
            exit 1
        fi
        sleep 2
    else
        echo -e "${GREEN}All containers are running${NC}"
    fi

    # Check if provisioned
    if ! check_provisioned; then
        echo -e "${YELLOW}Containers not provisioned. Current status:${NC}"
        echo -e "  infinibay-postgres:  $(get_provisioning_status 'infinibay-postgres')"
        echo -e "  infinibay-redis:     $(get_provisioning_status 'infinibay-redis')"
        echo -e "  infinibay-backend:   $(get_provisioning_status 'infinibay-backend')"
        echo -e "  infinibay-frontend:  $(get_provisioning_status 'infinibay-frontend')"
        echo -e "${YELLOW}Running provisioning...${NC}"
        if [[ ! -f "$SCRIPT_DIR/provisioning/provision-all.sh" ]]; then
            echo -e "${RED}Error: provisioning/provision-all.sh not found${NC}"
            exit 1
        fi
        sg lxd -c "bash '$SCRIPT_DIR/provisioning/provision-all.sh'"
    else
        echo -e "${GREEN}Containers are provisioned${NC}"
    fi

    # Final check to ensure everything is running
    if ! check_containers_running; then
        echo -e "${RED}Error: Some containers failed to start${NC}"
        exit 1
    fi

    echo -e "\n${GREEN}=== Infinibay is ready! ===${NC}"
    echo -e "\n${BLUE}Access URLs:${NC}"
    echo -e "  Frontend: ${GREEN}http://localhost:3000${NC}"
    echo -e "  Backend:  ${GREEN}http://localhost:4000/graphql${NC}"
    echo -e "\n${BLUE}Useful commands:${NC}"
    echo -e "  Status:   ${BLUE}./run.sh status${NC}"
    echo -e "  Logs:     ${BLUE}./run.sh logs <container-name>${NC}"
    echo -e "  Shell:    ${BLUE}./run.sh exec <container-name>${NC}"
}

# Main command handler
case "${1:-}" in
    "")
        smart_default
        ;;

    setup-profiles|sp)
        echo -e "${BLUE}=== Setting up profiles ===${NC}"
        setup_profiles
        ;;

    apply|a|ap)
        echo -e "${BLUE}=== Applying Infinibay configuration ===${NC}"
        ensure_data_dirs
        setup_profiles
        echo -e "${BLUE}Starting containers...${NC}"
        cd "$SCRIPT_DIR"
        sg lxd -c "LXD_DIR=$LXD_DIR lxd-compose apply infinibay"
        echo -e "${GREEN}Infinibay containers are running!${NC}"
        echo -e "\nTo check status: ${BLUE}lxc list${NC}"
        ;;

    destroy|d|de)
        echo -e "${YELLOW}=== Destroying Infinibay containers ===${NC}"
        cd "$SCRIPT_DIR"
        sg lxd -c "LXD_DIR=$LXD_DIR lxd-compose destroy infinibay"
        echo -e "${GREEN}Containers destroyed${NC}"
        ;;

    restart|r|re)
        echo -e "${BLUE}=== Restarting Infinibay ===${NC}"
        "$0" destroy
        "$0" apply
        ;;

    provision|p|pr)
        echo -e "${BLUE}=== Provisioning Infinibay Containers ===${NC}"
        if [[ ! -f "$SCRIPT_DIR/provisioning/provision-all.sh" ]]; then
            echo -e "${RED}Error: provisioning/provision-all.sh not found${NC}"
            exit 1
        fi
        sg lxd -c "bash '$SCRIPT_DIR/provisioning/provision-all.sh'"
        ;;

    redo|rd)
        echo -e "${BLUE}=== Redo: Destroy and recreate environment ===${NC}\n"
        if check_environment_exists; then
            echo -e "${YELLOW}Existing environment found. Destroying...${NC}"
            cd "$SCRIPT_DIR"
            sg lxd -c "LXD_DIR=$LXD_DIR lxd-compose destroy infinibay"
            echo -e "${GREEN}Containers destroyed${NC}\n"
        else
            echo -e "${YELLOW}No existing environment found. Will create fresh.${NC}\n"
        fi
        smart_default
        ;;

    status|s|st)
        echo -e "${BLUE}=== Infinibay Status ===${NC}"
        sg lxd -c "lxc list" | grep infinibay || echo "No Infinibay containers running"
        ;;

    exec|e|ex)
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

    logs|l|lo)
        if [[ -z "$2" ]]; then
            echo -e "${RED}Usage: $0 logs <container-name>${NC}"
            exit 1
        fi
        sg lxd -c "lxc exec 'infinibay-$2' -- journalctl -f"
        ;;

    help|--help|-h)
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay LXD Management Script                      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}Smart Default Behavior:${NC}"
        echo -e "  Running without arguments intelligently sets up your environment:"
        echo -e "  • Creates containers if they don't exist"
        echo -e "  • Starts containers if they're stopped"
        echo -e "  • Provisions containers if not yet provisioned"
        echo -e "  • Shows access URLs when ready"
        echo ""
        echo -e "${BLUE}Usage:${NC} $0 [command]"
        echo ""
        echo -e "${BLUE}Commands:${NC}                    ${BLUE}Shortcuts:${NC}"
        echo -e "  ${GREEN}(none)${NC}                      -           Smart default setup"
        echo -e "  ${GREEN}apply${NC}                       a, ap       Create/start all containers"
        echo -e "  ${GREEN}provision${NC}                   p, pr       Install software in all containers"
        echo -e "  ${GREEN}redo${NC}                        rd          Destroy and recreate with smart setup"
        echo -e "  ${GREEN}destroy${NC}                     d, de       Stop and remove all containers"
        echo -e "  ${GREEN}restart${NC}                     r, re       Destroy and recreate (legacy, use 'redo')"
        echo -e "  ${GREEN}status${NC}                      s, st       Show container status"
        echo -e "  ${GREEN}setup-profiles${NC}              sp          Generate and update LXD profiles only"
        echo -e "  ${GREEN}exec${NC} <name> [cmd]          e, ex       Execute command in container"
        echo -e "  ${GREEN}logs${NC} <name>                l, lo       Follow logs from container"
        echo -e "  ${GREEN}help${NC}                        -           Show this help"
        echo ""
        echo -e "${YELLOW}Prerequisites:${NC}"
        echo -e "  • Copy ${BLUE}values.yml.example${NC} to ${BLUE}values.yml${NC} and customize"
        echo -e "  • Configure ${BLUE}.env${NC} (auto-generated by setup.sh or copy from .env.example)"
        echo -e "  • ${YELLOW}IMPORTANT:${NC} Set a strong admin password in ${BLUE}.env${NC} (ADMIN_PASSWORD)"
        echo -e "  • Ensure LXD is initialized and your user is in the 'lxd' group"
        echo ""
        echo -e "${BLUE}Examples:${NC}"
        echo -e "  ${GREEN}$0${NC}                    # Smart setup - recommended!"
        echo -e "  ${GREEN}$0 s${NC}                   # Quick status check"
        echo -e "  ${GREEN}$0 rd${NC}                  # Fresh start (destroy + smart setup)"
        echo -e "  ${GREEN}$0 p${NC}                   # Provision containers"
        echo -e "  ${GREEN}$0 e backend bash${NC}      # Enter backend container"
        echo -e "  ${GREEN}$0 lo postgres${NC}         # View postgres logs"
        echo -e "  ${GREEN}$0 d${NC}                   # Destroy everything"
        echo ""
        echo -e "${BLUE}Container Names:${NC}"
        echo -e "  postgres, redis, backend, frontend"
        echo ""
        echo -e "${GREEN}After setup, access:${NC}"
        echo -e "  Frontend: ${BLUE}http://localhost:3000${NC}"
        echo -e "  Backend:  ${BLUE}http://localhost:4000/graphql${NC}"
        ;;

    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo -e "Run ${BLUE}$0 help${NC} for usage information"
        exit 1
        ;;
esac

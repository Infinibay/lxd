#!/bin/bash
# Infinibay LXD Management Script
# Handles profile generation and container lifecycle

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to check required commands
check_required_commands() {
    local missing_commands=()

    # Check for required commands
    if ! command -v sg &>/dev/null; then
        missing_commands+=("sg (from shadow-utils package)")
    fi

    if ! command -v lxc &>/dev/null; then
        missing_commands+=("lxc (LXD client)")
    fi

    if ! command -v lxd-compose &>/dev/null; then
        missing_commands+=("lxd-compose")
    fi

    # Report missing commands
    if [ ${#missing_commands[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required commands:${NC}"
        for cmd in "${missing_commands[@]}"; do
            echo -e "  - $cmd"
        done
        echo ""
        echo -e "${YELLOW}Please run setup.sh first to install dependencies.${NC}"
        exit 1
    fi
}

# Function to check if user is in lxd group
check_lxd_group() {
    if ! groups | grep -qw lxd; then
        echo -e "${RED}Error: Current user is not in the 'lxd' group${NC}"
        echo ""
        echo -e "${YELLOW}To fix this, run one of the following:${NC}"
        echo -e "  1. Activate group in current session: ${BLUE}newgrp lxd${NC}"
        echo -e "  2. Or logout and login again"
        echo ""
        echo -e "${YELLOW}If you haven't run setup yet:${NC}"
        echo -e "  ${BLUE}sudo ./setup.sh${NC}"
        exit 1
    fi
}

# Check required commands before proceeding
check_required_commands

# Check if user is in lxd group
check_lxd_group

# Get absolute path to infinibay directory (parent of lxd/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFINIBAY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/lxd-path.sh"
source "$SCRIPT_DIR/lib/provisioning-state.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/rollback.sh"
source "$SCRIPT_DIR/lib/health-checks.sh"
source "$SCRIPT_DIR/lib/upgrade-manifest.sh"
source "$SCRIPT_DIR/lib/progress.sh"
source "$SCRIPT_DIR/lib/error-messages.sh"

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
    mkdir -p "$INFINIBAY_DIR/data"/{postgres,backend,frontend}
    # Set permissions so containers can write to these directories
    # LXD uses user namespaces, so we need to make directories writable
    chmod 777 "$INFINIBAY_DIR/data"/{postgres,backend,frontend}
    echo -e "${GREEN}Data directories ready${NC}"
}

# Helper function to check if infinibay environment exists
# Verifies that all three expected containers exist
check_environment_exists() {
    local containers=("infinibay-postgres" "infinibay-backend" "infinibay-frontend")
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
    local containers=("infinibay-postgres" "infinibay-backend" "infinibay-frontend")
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
    local containers=("infinibay-postgres" "infinibay-backend" "infinibay-frontend")
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
    local containers=("infinibay-postgres" "infinibay-backend" "infinibay-frontend")
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

# Helper function to check if VMs are running in backend container
check_vms_running() {
    set +e
    local output=$(sg lxd -c "lxc exec infinibay-backend -- virsh list --state-running 2>/dev/null")
    local exit_code=$?
    set -e

    # Check if backend container is running and virsh is available
    if [[ $exit_code -ne 0 ]]; then
        return 1  # Backend not available or virsh failed
    fi

    # Count running VMs (skip first 2 header lines and count non-empty lines)
    local vm_count=$(echo "$output" | tail -n +3 | grep -v "^$" | wc -l)

    if [[ $vm_count -gt 0 ]]; then
        echo "$vm_count"
        return 0  # VMs are running
    else
        return 1  # No VMs running
    fi
}

# Helper function to stop frontend container
stop_frontend_container() {
    local force_mode=$1

    echo -e "${BLUE}Stopping frontend container...${NC}"

    set +e
    local state=$(sg lxd -c "lxc list infinibay-frontend --format=csv -c s" 2>/dev/null)
    set -e

    if [[ -z "$state" ]]; then
        echo -e "  ${YELLOW}Frontend container does not exist${NC}"
        return 0
    fi

    if [[ "$state" != "RUNNING" ]]; then
        echo -e "  ${YELLOW}Frontend container is already stopped${NC}"
        return 0
    fi

    # Stop systemd service if running
    set +e
    sg lxd -c "lxc exec infinibay-frontend -- systemctl stop infinibay-frontend" 2>/dev/null
    set -e

    # Wait for graceful shutdown unless force mode
    if [[ "$force_mode" == "false" ]]; then
        sleep 2
    fi

    # Stop the LXD container
    set +e
    if [[ "$force_mode" == "true" ]]; then
        sg lxd -c "lxc stop infinibay-frontend --force"
    else
        sg lxd -c "lxc stop infinibay-frontend --timeout 30"
    fi
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        echo -e "  ${GREEN}Frontend container stopped successfully${NC}"
        return 0
    else
        echo -e "  ${RED}Failed to stop frontend container${NC}"
        return 1
    fi
}

# Helper function to stop backend container
stop_backend_container() {
    local force_mode=$1

    echo -e "${BLUE}Stopping backend container...${NC}"

    set +e
    local state=$(sg lxd -c "lxc list infinibay-backend --format=csv -c s" 2>/dev/null)
    set -e

    if [[ -z "$state" ]]; then
        echo -e "  ${YELLOW}Backend container does not exist${NC}"
        return 0
    fi

    if [[ "$state" != "RUNNING" ]]; then
        echo -e "  ${YELLOW}Backend container is already stopped${NC}"
        return 0
    fi

    # Stop systemd service if running
    set +e
    sg lxd -c "lxc exec infinibay-backend -- systemctl stop infinibay-backend" 2>/dev/null
    set -e

    # Wait for graceful shutdown unless force mode
    if [[ "$force_mode" == "false" ]]; then
        sleep 2
    fi

    # Stop the LXD container
    set +e
    if [[ "$force_mode" == "true" ]]; then
        sg lxd -c "lxc stop infinibay-backend --force"
    else
        sg lxd -c "lxc stop infinibay-backend --timeout 30"
    fi
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        echo -e "  ${GREEN}Backend container stopped successfully${NC}"
        return 0
    else
        echo -e "  ${RED}Failed to stop backend container${NC}"
        return 1
    fi
}

# Helper function to stop postgres container
stop_postgres_container() {
    local force_mode=$1

    echo -e "${BLUE}Stopping postgres container...${NC}"

    set +e
    local state=$(sg lxd -c "lxc list infinibay-postgres --format=csv -c s" 2>/dev/null)
    set -e

    if [[ -z "$state" ]]; then
        echo -e "  ${YELLOW}Postgres container does not exist${NC}"
        return 0
    fi

    if [[ "$state" != "RUNNING" ]]; then
        echo -e "  ${YELLOW}Postgres container is already stopped${NC}"
        return 0
    fi

    # If not in force mode, wait for active connections to close
    if [[ "$force_mode" == "false" ]]; then
        echo -e "  ${BLUE}Waiting for active connections to close (max 30s)...${NC}"
        local timeout=30
        local elapsed=0

        while [[ $elapsed -lt $timeout ]]; do
            set +e
            local conn_count=$(sg lxd -c "lxc exec infinibay-postgres -- su - postgres -c 'psql -t -c \"SELECT count(*) FROM pg_stat_activity WHERE datname = '\'infinibay\'' AND pid <> pg_backend_pid();\"'" 2>/dev/null | tr -d ' ')
            local psql_exit_code=$?
            set -e

            # If query failed or returned empty, warn and continue
            if [[ $psql_exit_code -ne 0 ]] || [[ -z "$conn_count" ]]; then
                if [[ $elapsed -eq 0 ]]; then
                    echo -e "  ${YELLOW}Warning: Could not check active connections${NC}"
                fi
                sleep 1
                elapsed=$((elapsed + 1))
                continue
            fi

            # Only treat conn_count == "0" as success
            if [[ "$conn_count" == "0" ]]; then
                echo -e "  ${GREEN}All connections closed${NC}"
                break
            fi

            if [[ $elapsed -eq 0 ]]; then
                echo -e "  ${YELLOW}Waiting for $conn_count active connection(s) to close...${NC}"
            fi

            sleep 1
            elapsed=$((elapsed + 1))
        done

        if [[ $elapsed -ge $timeout ]]; then
            echo -e "  ${YELLOW}Warning: Timeout reached with active connections still present${NC}"
        fi
    fi

    # Stop PostgreSQL service inside container
    set +e
    sg lxd -c "lxc exec infinibay-postgres -- systemctl stop postgresql" 2>/dev/null
    set -e

    # Wait for graceful shutdown
    if [[ "$force_mode" == "false" ]]; then
        sleep 2
    fi

    # Stop the LXD container
    set +e
    if [[ "$force_mode" == "true" ]]; then
        sg lxd -c "lxc stop infinibay-postgres --force"
    else
        sg lxd -c "lxc stop infinibay-postgres --timeout 30"
    fi
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        echo -e "  ${GREEN}Postgres container stopped successfully${NC}"
        return 0
    else
        echo -e "  ${RED}Failed to stop postgres container${NC}"
        return 1
    fi
}

# Main orchestration function to stop all containers
stop_all_containers() {
    local force_mode=$1
    local check_vms=$2

    echo -e "${BLUE}=== Stopping Infinibay Containers ===${NC}\n"

    # Check if VMs are running (if requested)
    if [[ "$check_vms" == "true" ]]; then
        set +e
        local vm_count=$(check_vms_running)
        local has_vms=$?
        set -e

        if [[ $has_vms -eq 0 ]]; then
            echo -e "${YELLOW}Warning: $vm_count VM(s) are currently running${NC}"
            echo -ne "${YELLOW}Stop containers anyway? This may affect running VMs. (y/N): ${NC}"
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Stop operation cancelled by user${NC}"
                return 2
            fi
            echo ""
        fi
    fi

    # Check if environment exists
    if ! check_environment_exists; then
        echo -e "${YELLOW}No Infinibay containers found. Nothing to stop.${NC}"
        return 0
    fi

    # Track failures
    local has_failure=0

    # Stop containers in reverse order: frontend → backend → postgres
    if ! stop_frontend_container "$force_mode"; then
        has_failure=1
    fi
    echo ""

    if ! stop_backend_container "$force_mode"; then
        has_failure=1
    fi
    echo ""

    if ! stop_postgres_container "$force_mode"; then
        has_failure=1
    fi

    # Print summary
    echo ""
    if [[ $has_failure -eq 0 ]]; then
        echo -e "${GREEN}=== All containers stopped successfully ===${NC}"
        return 0
    else
        echo -e "${RED}=== Some containers failed to stop ===${NC}"
        echo -e "${YELLOW}Check the output above for details${NC}"
        return 1
    fi
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

# Best-effort mDNS discovery of an Infinibay master on the LAN. Returns a master
# URL on stdout (empty if none found). Used by 'join' when the master is "auto".
discover_master() {
    local svc="_infinibay-master._tcp"
    local host="" port=""
    if command -v avahi-browse >/dev/null 2>&1; then
        # -t terminate, -r resolve, -p parsable. Take the first resolved record.
        local line
        line="$(avahi-browse -tprk "$svc" 2>/dev/null | awk -F';' '$1=="=" {print $8";"$9; exit}')"
        host="${line%%;*}"; port="${line##*;}"
    elif command -v dns-sd >/dev/null 2>&1; then
        # macOS / mDNSResponder; dns-sd has no clean one-shot, so skip resolving.
        host=""
    fi
    if [[ -n "$host" && -n "$port" ]]; then
        echo "http://${host}:${port}"
    fi
}

# Normalize 'help <subcommand>' to 'help-<subcommand>' pattern
# This allows both './run.sh help update' and './run.sh help-update' to work
if [[ "${1:-}" == "help" && -n "${2:-}" ]]; then
    case "$2" in
        update|u|up)
            set -- "help-update"
            ;;
        upgrade|ug)
            set -- "help-upgrade"
            ;;
        join|jn)
            set -- "help-join"
            ;;
    esac
fi

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

    join|jn)
        # Onboard THIS host as a compute node of an existing master cluster.
        # Wraps `npm run agent:join` (SAS-verified mTLS enrollment) in the agent
        # container, then points the operator at the next (start-agent) step.
        master_url="${2:-}"
        token="${3:-}"
        node_name="${4:-$(hostname)}"
        container="${INFINIBAY_AGENT_CONTAINER:-infinibay-backend}"

        discovered_via_mdns=0
        if [[ "$master_url" == "auto" || -z "$master_url" ]]; then
            echo -e "${BLUE}Discovering an Infinibay master via mDNS...${NC}"
            master_url="$(discover_master)"
            if [[ -z "$master_url" ]]; then
                echo -e "${RED}No master found via mDNS.${NC}"
                echo -e "Usage: $0 join <master-url> <token> [node-name]"
                exit 1
            fi
            discovered_via_mdns=1
            echo -e "${GREEN}Found master:${NC} $master_url"
        fi
        if [[ -z "$token" ]]; then
            echo -e "${RED}Error: a cluster bootstrap token is required${NC}"
            echo -e "Usage: $0 join <master-url> <token> [node-name]"
            echo -e "Detailed help: $0 help join"
            exit 1
        fi

        # SECURITY: validate every value that is later interpolated into a
        # privileged shell command (sg lxd -c "... npm run agent:join"). Without
        # this, a token/node-name/URL containing shell metacharacters (e.g.
        # "x'; rm -rf / ; echo '") would break out of the quoting and run as the
        # lxd group on the host (root-equivalent via LXD). Reject anything outside
        # a conservative safe set.
        if [[ ! "$master_url" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\'\(\)*+,\;=%-]+$ ]]; then
            echo -e "${RED}Error: master URL contains unexpected characters: ${master_url}${NC}"; exit 1
        fi
        if [[ ! "$token" =~ ^[A-Za-z0-9._+=/:-]+$ ]]; then
            echo -e "${RED}Error: the cluster token contains characters outside the allowed set [A-Za-z0-9._+=/:-]${NC}"; exit 1
        fi
        if [[ ! "$node_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo -e "${RED}Error: node name must match [A-Za-z0-9._-]: ${node_name}${NC}"; exit 1
        fi
        if [[ ! "$container" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo -e "${RED}Error: container name must match [A-Za-z0-9._-]: ${container}${NC}"; exit 1
        fi

        # SECURITY: mDNS discovery is UNAUTHENTICATED — any host on the LAN can
        # advertise _infinibay-master._tcp. Do not ship the bootstrap token to an
        # auto-discovered peer without the operator confirming it is the real
        # master (the SAS pairing code is only checked AFTER the token is sent).
        if [[ "$discovered_via_mdns" == "1" ]]; then
            echo -e "${YELLOW}This master was found via mDNS and is NOT authenticated. Anyone on the"
            echo -e "network can advertise it. The bootstrap token will be sent to it FIRST,"
            echo -e "before the pairing-code check. Only continue if you trust ${master_url}.${NC}"
            read -r -p "Send the bootstrap token to ${master_url}? [y/N] " _confirm
            if [[ "${_confirm}" != "y" && "${_confirm}" != "Y" ]]; then
                echo -e "${RED}Aborted. Pass the master URL explicitly to skip mDNS discovery.${NC}"; exit 1
            fi
        fi

        master_host="${master_url#*://}"; master_host="${master_host%%/*}"; master_host="${master_host%%:*}"

        echo -e "${BLUE}=== Joining cluster as node '${node_name}' ===${NC}"
        echo -e "  Master:    ${master_url}"
        echo -e "  Node name: ${node_name}"
        echo -e "  Container: ${container}"
        echo ""
        echo -e "${YELLOW}A 6-digit PAIRING CODE will be printed below. Compare it with the code"
        echo -e "shown for this node in the master's Infrastructure UI, then APPROVE it there."
        echo -e "If the codes differ, the connection may be tampered with — do NOT approve.${NC}"
        echo ""

        if ! sg lxd -c "lxc exec '$container' -- su - infinibay -c 'cd /opt/infinibay/backend && MASTER_URL=\"$master_url\" INFINIBAY_CLUSTER_TOKEN=\"$token\" INFINIBAY_NODE_NAME=\"$node_name\" npm run agent:join'"; then
            echo -e "\n${RED}Join failed. Check the master URL/token and that container '${container}' is running.${NC}"
            exit 1
        fi

        echo -e "\n${GREEN}Node '${node_name}' enrolled — its client certificate was issued.${NC}"
        echo -e "${BLUE}Next — start the node agent in mTLS mode${NC} (set in its environment, then run ${GREEN}npm run agent:heartbeat${NC}):"
        echo -e "  ${CYAN}INFINIBAY_CLUSTER_MTLS=1${NC}"
        echo -e "  ${CYAN}MASTER_CLUSTER_URL=https://${master_host}:4433${NC}   ${YELLOW}# the master's mTLS port${NC}"
        echo -e "  ${CYAN}INFINIBAY_MASTER_CN=<the master's node name>${NC}"
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

    stop|st|sto)
        force_mode="false"
        check_vms="false"

        # Parse options
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --force)
                    force_mode="true"
                    shift
                    ;;
                --check-vms)
                    check_vms="true"
                    shift
                    ;;
                *)
                    echo -e "${RED}Unknown option: $1${NC}"
                    echo -e "Usage: $0 stop [--force] [--check-vms]"
                    exit 1
                    ;;
            esac
        done

        # Call the stop orchestration function
        stop_all_containers "$force_mode" "$check_vms"
        exit $?
        ;;

    update|u|up)
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay Update System                              ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        display_time_estimate "total-update" "Estimated total time:"

        # ========================================
        # Phase 0: LXD Self-Update
        # ========================================
        start_phase "Phase 0: LXD Self-Update" 3

        # Save current script context for potential re-execution
        SCRIPT_PATH="$(realpath "$0")"
        SCRIPT_ARGS="$@"
        LXD_DIR="$SCRIPT_DIR"

        # Navigate to LXD directory
        cd "$LXD_DIR"

        # Fetch latest changes from origin
        update_step 1 "Checking for LXD repository updates" "in-progress"
        set +e
        git fetch origin 2>&1
        fetch_exit_code=$?
        set -e

        if [[ $fetch_exit_code -ne 0 ]]; then
            update_step 1 "Checking for LXD repository updates" "failed"
            error_git_operation_failed "fetch" "lxd" "Could not reach remote repository"
            exit 1
        fi
        update_step 1 "Checking for LXD repository updates" "complete"

        # Capture current and remote commits
        update_step 2 "Resolving commit references" "in-progress"
        set +e
        LXD_OLD_COMMIT=$(git rev-parse HEAD 2>/dev/null)
        old_commit_exit_code=$?
        set -e

        if [[ $old_commit_exit_code -ne 0 ]]; then
            update_step 2 "Resolving commit references" "failed"
            error_git_operation_failed "rev-parse" "lxd" "Failed to resolve current commit (HEAD). Ensure you are in a valid git repository."
            exit 1
        fi

        set +e
        LXD_NEW_COMMIT=$(git rev-parse origin/main 2>/dev/null)
        new_commit_exit_code=$?
        set -e

        if [[ $new_commit_exit_code -ne 0 ]]; then
            update_step 2 "Resolving commit references" "failed"
            error_git_operation_failed "rev-parse" "lxd" "Failed to resolve remote commit (origin/main). Ensure the remote branch exists."
            exit 1
        fi
        update_step 2 "Resolving commit references" "complete"

        # Check if updates are available
        if [[ "$LXD_OLD_COMMIT" != "$LXD_NEW_COMMIT" ]]; then
            update_step 3 "Pulling LXD updates" "in-progress"

            # Pull updates
            set +e
            git pull origin main
            pull_exit_code=$?
            set -e

            if [[ $pull_exit_code -ne 0 ]]; then
                update_step 3 "Pulling LXD updates" "failed"
                error_git_operation_failed "pull" "lxd" "Could not merge remote changes"
                exit 1
            fi

            # Check if run.sh changed
            set +e
            git diff --name-only "$LXD_OLD_COMMIT" "$LXD_NEW_COMMIT" | grep -q "run.sh"
            run_sh_changed=$?
            set -e

            if [[ $run_sh_changed -eq 0 ]]; then
                update_step 3 "Pulling LXD updates" "complete"
                echo -e "${YELLOW}Update script itself changed. Re-executing with new version...${NC}"
                echo ""
                exec "$SCRIPT_PATH" $SCRIPT_ARGS
                # This line never returns - the process is replaced
            else
                update_step 3 "Pulling LXD updates" "complete"
                LXD_UPDATED=true
            fi
        else
            update_step 3 "LXD repository already up to date" "skipped"
            LXD_UPDATED=false
        fi

        phase_summary "Phase 0: LXD Self-Update" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Pre-flight Checks
        # ========================================
        start_phase "Pre-flight Checks" 1
        update_step 1 "Running pre-flight checks" "in-progress"

        if ! run_all_preflight_checks; then
            update_step 1 "Running pre-flight checks" "failed"
            error_preflight_failed "containers" "One or more pre-flight checks failed" "Check the output above for specific failures"
            exit 1
        fi

        update_step 1 "Running pre-flight checks" "complete"
        phase_summary "Pre-flight Checks" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Phase 1: Backup
        # ========================================
        start_phase "Phase 1: Backup" 2
        display_time_estimate "backup"

        # Create backup using backup.sh library
        update_step 1 "Creating system backup" "in-progress"
        set +e
        BACKUP_OUTPUT=$(create_backup "update" 2>&1)
        backup_exit_code=$?
        set -e

        if [[ $backup_exit_code -ne 0 ]]; then
            update_step 1 "Creating system backup" "failed"
            error_preflight_failed "backup-writable" "Backup creation failed" "Check disk space and permissions on /data/backups"
            echo "$BACKUP_OUTPUT"
            exit 1
        fi
        update_step 1 "Creating system backup" "complete"

        # Extract backup path from output
        # backup.sh prints "Backup name: <name>" and "Location: <path>"
        update_step 2 "Validating backup" "in-progress"
        BACKUP_PATH=$(echo "$BACKUP_OUTPUT" | grep "Location:" | sed 's/.*Location: //' | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n' | xargs)

        if [[ -z "$BACKUP_PATH" ]]; then
            update_step 2 "Validating backup" "failed"
            echo -e "${RED}Failed to extract backup path from create_backup output${NC}"
            echo -e "${RED}This is a critical error - cannot proceed without valid backup${NC}"
            echo ""
            echo -e "${YELLOW}create_backup output:${NC}"
            echo "$BACKUP_OUTPUT"
            exit 1
        fi

        # Validate backup path exists in postgres container
        set +e
        sg lxd -c "lxc exec infinibay-postgres -- test -d '$BACKUP_PATH'" 2>/dev/null
        backup_dir_exists=$?
        set -e

        if [[ $backup_dir_exists -ne 0 ]]; then
            update_step 2 "Validating backup" "failed"
            echo -e "${RED}Backup path does not exist in postgres container: $BACKUP_PATH${NC}"
            echo -e "${RED}Cannot proceed without valid backup${NC}"
            exit 1
        fi

        update_step 2 "Validating backup" "complete"
        echo -e "${GREEN}Backup location: ${CYAN}$BACKUP_PATH${NC}"
        phase_summary "Phase 1: Backup" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Phase 2: Update Repositories
        # ========================================
        echo -e "${BLUE}=== Phase 2: Update Repositories ===${NC}"
        echo ""

        # Track if libvirt-node was updated (affects backend npm install)
        LIBVIRT_UPDATED=false

        # ========================================
        # Phase 2.1: Update libvirt-node
        # ========================================
        start_phase "Phase 2.1: Update libvirt-node" 6
        display_time_estimate "libvirt-node-build"

        # Navigate to libvirt-node in backend container
        update_step 1 "Checking for libvirt-node updates" "in-progress"

        set +e
        OLD_LIBVIRT_COMMIT=$(sg lxd -c "lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node rev-parse HEAD" 2>/dev/null)
        old_commit_status=$?
        set -e

        if [[ $old_commit_status -ne 0 ]]; then
            update_step 1 "Checking for libvirt-node updates" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_git_operation_failed "rev-parse" "libvirt-node" "Failed to get current commit"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        set +e
        sg lxd -c "lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node fetch origin" 2>&1
        fetch_status=$?
        set -e

        if [[ $fetch_status -ne 0 ]]; then
            update_step 1 "Checking for libvirt-node updates" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_git_operation_failed "fetch" "libvirt-node" "Could not reach remote repository"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        set +e
        NEW_LIBVIRT_COMMIT=$(sg lxd -c "lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node rev-parse origin/main" 2>/dev/null)
        new_commit_status=$?
        set -e

        if [[ $new_commit_status -ne 0 ]]; then
            update_step 1 "Checking for libvirt-node updates" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_git_operation_failed "rev-parse" "libvirt-node" "Failed to get remote commit"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        update_step 1 "Checking for libvirt-node updates" "complete"

        # Compare commits
        if [[ "$OLD_LIBVIRT_COMMIT" != "$NEW_LIBVIRT_COMMIT" ]]; then
            echo -e "${DIM}Updates available: ${OLD_LIBVIRT_COMMIT:0:7} → ${NEW_LIBVIRT_COMMIT:0:7}${NC}"

            # Pull updates
            update_step 2 "Pulling libvirt-node updates" "in-progress"
            set +e
            sg lxd -c "lxc exec infinibay-backend -- git -C /opt/infinibay/libvirt-node pull origin main" 2>&1
            pull_status=$?
            set -e

            if [[ $pull_status -ne 0 ]]; then
                update_step 2 "Pulling libvirt-node updates" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_git_operation_failed "pull" "libvirt-node" "Could not merge remote changes"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 2 "Pulling libvirt-node updates" "complete"

            # Install npm dependencies
            update_step 3 "Installing libvirt-node dependencies" "in-progress"
            set +e
            sg lxd -c "lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/libvirt-node && npm install'" 2>&1
            install_status=$?
            set -e

            if [[ $install_status -ne 0 ]]; then
                update_step 3 "Installing libvirt-node dependencies" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_npm_operation_failed "install" "libvirt-node"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 3 "Installing libvirt-node dependencies" "complete"

            # Capture old .node file modification time
            set +e
            OLD_NODE_MTIME=$(sg lxd -c "lxc exec infinibay-backend -- sh -c 'stat -c %Y /opt/infinibay/libvirt-node/*.node 2>/dev/null | head -1'" 2>/dev/null)
            set -e
            OLD_NODE_MTIME=${OLD_NODE_MTIME:-0}

            # Build Rust module
            update_step 4 "Building Rust module (this takes 5-10 minutes)" "in-progress"
            set +e
            sg lxd -c "lxc exec infinibay-backend -- su - infinibay -c 'source ~/.cargo/env && cd /opt/infinibay/libvirt-node && npm run build'" 2>&1
            build_status=$?
            set -e

            if [[ $build_status -ne 0 ]]; then
                update_step 4 "Building Rust module" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_build_failed "libvirt-node" "/opt/infinibay/libvirt-node/build.log" "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 4 "Building Rust module" "complete"

            # Verify .node file exists
            update_step 5 "Verifying build artifacts" "in-progress"
            set +e
            NODE_FILE_EXISTS=$(sg lxd -c "lxc exec infinibay-backend -- sh -c 'ls /opt/infinibay/libvirt-node/*.node 2>/dev/null | head -1'")
            node_exists_status=$?
            set -e

            if [[ $node_exists_status -ne 0 ]] || [[ -z "$NODE_FILE_EXISTS" ]]; then
                update_step 5 "Verifying build artifacts" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_build_failed "libvirt-node" "/opt/infinibay/libvirt-node/build.log" "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi

            # Verify modification time changed (fresh build)
            set +e
            NEW_NODE_MTIME=$(sg lxd -c "lxc exec infinibay-backend -- sh -c 'stat -c %Y /opt/infinibay/libvirt-node/*.node 2>/dev/null | head -1'" 2>/dev/null)
            set -e

            if [[ -z "$NEW_NODE_MTIME" ]] || [[ "$NEW_NODE_MTIME" -le "$OLD_NODE_MTIME" ]]; then
                update_step 5 "Verifying build artifacts" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_build_failed "libvirt-node" "/opt/infinibay/libvirt-node/build.log" "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 5 "Verifying build artifacts" "complete"

            # Package for backend
            update_step 6 "Packaging libvirt-node for backend" "in-progress"

            # Clean old tarballs from libvirt-node directory
            set +e
            sg lxd -c "lxc exec infinibay-backend -- bash -c 'rm -f /opt/infinibay/libvirt-node/infinibay-libvirt-node-*.tgz'" 2>&1
            set -e

            # Clean old tarballs from backend lib directory
            set +e
            sg lxd -c "lxc exec infinibay-backend -- bash -c 'rm -f /opt/infinibay/backend/lib/libvirt-node/infinibay-libvirt-node-*.tgz'" 2>&1
            set -e

            # Create fresh tarball
            set +e
            sg lxd -c "lxc exec infinibay-backend -- bash -c 'cd /opt/infinibay/libvirt-node && npm pack'" 2>&1
            pack_status=$?
            set -e

            if [[ $pack_status -ne 0 ]]; then
                update_step 6 "Packaging libvirt-node for backend" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_npm_operation_failed "pack" "libvirt-node"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi

            # Get the exact tarball name (newest file)
            set +e
            TARBALL_NAME=$(sg lxd -c "lxc exec infinibay-backend -- bash -c 'ls -t /opt/infinibay/libvirt-node/infinibay-libvirt-node-*.tgz 2>/dev/null | head -1'" 2>/dev/null)
            tarball_status=$?
            set -e

            if [[ $tarball_status -ne 0 ]] || [[ -z "$TARBALL_NAME" ]]; then
                update_step 6 "Packaging libvirt-node for backend" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_npm_operation_failed "pack" "libvirt-node" "Tarball not found after npm pack"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi

            # Copy the specific tarball to backend lib directory
            set +e
            sg lxd -c "lxc exec infinibay-backend -- bash -c 'mkdir -p /opt/infinibay/backend/lib/libvirt-node && cp $TARBALL_NAME /opt/infinibay/backend/lib/libvirt-node/'" 2>&1
            copy_status=$?
            set -e

            if [[ $copy_status -ne 0 ]]; then
                update_step 6 "Packaging libvirt-node for backend" "failed"
                display_rollback_notice "$BACKUP_PATH"
                echo -e "${RED}Failed to copy libvirt-node package to backend${NC}"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi

            update_step 6 "Packaging libvirt-node for backend" "complete"
            LIBVIRT_UPDATED=true
            phase_summary "Phase 2.1: Update libvirt-node" "$PROGRESS_PHASE_START_TIME" "success"
        else
            update_step 2 "No updates available" "skipped"
            update_step 3 "Installing dependencies" "skipped"
            update_step 4 "Building Rust module" "skipped"
            update_step 5 "Verifying build" "skipped"
            update_step 6 "Packaging" "skipped"
            LIBVIRT_UPDATED=false
            phase_summary "Phase 2.1: Update libvirt-node" "$PROGRESS_PHASE_START_TIME" "skipped"
        fi

        # ========================================
        # Phase 2.2: Update Backend
        # ========================================
        start_phase "Phase 2.2: Update Backend" 8
        display_time_estimate "backend-build"

        # Pull backend updates
        update_step 1 "Pulling backend updates" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-backend -- git -C /opt/infinibay/backend pull origin main" 2>&1
        backend_pull_status=$?
        set -e

        if [[ $backend_pull_status -ne 0 ]]; then
            update_step 1 "Pulling backend updates" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_git_operation_failed "pull" "backend" "Could not merge remote changes"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi
        update_step 1 "Pulling backend updates" "complete"

        # Check if package.json changed
        set +e
        PACKAGE_JSON_CHANGED=$(sg lxd -c "lxc exec infinibay-backend -- git -C /opt/infinibay/backend diff HEAD@{1} HEAD -- package.json" 2>/dev/null)
        set -e

        # Install dependencies if package.json changed OR libvirt-node was updated
        if [[ -n "$PACKAGE_JSON_CHANGED" ]] || [[ "$LIBVIRT_UPDATED" == "true" ]]; then
            update_step 2 "Installing backend dependencies" "in-progress"

            # Remove package-lock to regenerate with new libvirt-node
            set +e
            sg lxd -c "lxc exec infinibay-backend -- rm -f /opt/infinibay/backend/package-lock.json" 2>&1
            set -e

            set +e
            sg lxd -c "lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && npm install'" 2>&1
            backend_install_status=$?
            set -e

            if [[ $backend_install_status -ne 0 ]]; then
                update_step 2 "Installing backend dependencies" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_npm_operation_failed "install" "backend"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 2 "Installing backend dependencies" "complete"
        else
            update_step 2 "Dependencies unchanged" "skipped"
        fi

        # Build backend TypeScript
        update_step 3 "Building backend TypeScript" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-backend -- su - infinibay -c 'cd /opt/infinibay/backend && npm run build'" 2>&1
        backend_build_status=$?
        set -e

        if [[ $backend_build_status -ne 0 ]]; then
            update_step 3 "Building backend TypeScript" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_build_failed "backend" "/opt/infinibay/backend/build.log" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi
        update_step 3 "Building backend TypeScript" "complete"

        # Generate Prisma Client
        update_step 4 "Generating Prisma client" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-backend -- bash -c 'cd /opt/infinibay/backend && npx prisma generate'" 2>&1
        prisma_gen_status=$?
        set -e

        if [[ $prisma_gen_status -ne 0 ]]; then
            update_step 4 "Generating Prisma client" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_build_failed "backend" "/opt/infinibay/backend/prisma/schema.prisma" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi
        update_step 4 "Generating Prisma client" "complete"

        # Apply database migrations
        update_step 5 "Applying database migrations" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-backend -- bash -c 'source /opt/infinibay/backend/.env && export DATABASE_URL && cd /opt/infinibay/backend && npx prisma migrate deploy'" 2>&1
        migrate_status=$?
        set -e

        if [[ $migrate_status -ne 0 ]]; then
            update_step 5 "Applying database migrations" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_migration_failed "prisma" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi
        update_step 5 "Applying database migrations" "complete"

        # Run data migrations if they exist
        set +e
        DATA_MIGRATION_SCRIPT_EXISTS=$(sg lxd -c "lxc exec infinibay-backend -- test -f /opt/infinibay/backend/prisma/data-migrations/run.sh && echo 'yes' || echo 'no'" 2>/dev/null)
        set -e

        if [[ "$DATA_MIGRATION_SCRIPT_EXISTS" == "yes" ]]; then
            update_step 6 "Running data migrations" "in-progress"
            set +e
            sg lxd -c "lxc exec infinibay-backend -- bash /opt/infinibay/backend/prisma/data-migrations/run.sh" 2>&1
            data_migrate_status=$?
            set -e

            if [[ $data_migrate_status -ne 0 ]]; then
                update_step 6 "Running data migrations" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_migration_failed "data" "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 6 "Running data migrations" "complete"
        else
            update_step 6 "No data migrations" "skipped"
        fi

        # Restart backend service
        update_step 7 "Restarting backend service" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-backend -- systemctl restart infinibay-backend" 2>&1
        restart_status=$?
        set -e

        if [[ $restart_status -ne 0 ]]; then
            update_step 7 "Restarting backend service" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_service_restart_failed "backend" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        # Wait for backend service to become active (max 30 seconds)
        update_step 8 "Waiting for backend service" "in-progress"
        for i in {1..30}; do
            set +e
            sg lxd -c "lxc exec infinibay-backend -- systemctl is-active --quiet infinibay-backend" 2>/dev/null
            backend_active=$?
            set -e

            if [[ $backend_active -eq 0 ]]; then
                break
            fi

            if [[ $i -eq 30 ]]; then
                update_step 8 "Waiting for backend service" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_health_check_failed "backend" "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi

            sleep 1
        done
        update_step 8 "Waiting for backend service" "complete"

        phase_summary "Phase 2.2: Update Backend" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Phase 2.3: Update Frontend
        # ========================================
        start_phase "Phase 2.3: Update Frontend" 6
        display_time_estimate "frontend-build"

        # Pull frontend updates
        update_step 1 "Pulling frontend updates" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-frontend -- git -C /opt/infinibay/frontend pull origin main" 2>&1
        frontend_pull_status=$?
        set -e

        if [[ $frontend_pull_status -ne 0 ]]; then
            update_step 1 "Pulling frontend updates" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_git_operation_failed "pull" "frontend" "Could not merge remote changes"
            echo -e "${YELLOW}Rolling back...${NC}"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        update_step 1 "Pulling frontend updates" "complete"

        # Check if package.json changed
        set +e
        FRONTEND_PACKAGE_JSON_CHANGED=$(sg lxd -c "lxc exec infinibay-frontend -- git -C /opt/infinibay/frontend diff HEAD@{1} HEAD -- package.json" 2>/dev/null)
        set -e

        # Install dependencies if package.json changed
        if [[ -n "$FRONTEND_PACKAGE_JSON_CHANGED" ]]; then
            update_step 2 "Installing frontend dependencies" "in-progress"
            set +e
            sg lxd -c "lxc exec infinibay-frontend -- su - infinibay -c 'cd /opt/infinibay/frontend && HUSKY=0 npm install'" 2>&1
            frontend_install_status=$?
            set -e

            if [[ $frontend_install_status -ne 0 ]]; then
                update_step 2 "Installing frontend dependencies" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_npm_operation_failed "install" "frontend"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi
            update_step 2 "Installing frontend dependencies" "complete"
        else
            update_step 2 "Dependencies unchanged" "skipped"
        fi

        # ALWAYS run codegen to sync with backend schema
        update_step 3 "Running GraphQL codegen" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-frontend -- su - infinibay -c 'cd /opt/infinibay/frontend && npm run codegen'" 2>&1
        codegen_status=$?
        set -e

        if [[ $codegen_status -ne 0 ]]; then
            update_step 3 "Running GraphQL codegen" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_build_failed "frontend" "/opt/infinibay/frontend/codegen.log" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi
        update_step 3 "Running GraphQL codegen" "complete"

        # Build frontend
        update_step 4 "Building frontend (Next.js)" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-frontend -- su - infinibay -c 'cd /opt/infinibay/frontend && npm run build'" 2>&1
        frontend_build_status=$?
        set -e

        if [[ $frontend_build_status -ne 0 ]]; then
            update_step 4 "Building frontend (Next.js)" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_build_failed "frontend" "/opt/infinibay/frontend/.next/build.log" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi
        update_step 4 "Building frontend (Next.js)" "complete"

        # Restart frontend service
        update_step 5 "Restarting frontend service" "in-progress"
        set +e
        sg lxd -c "lxc exec infinibay-frontend -- systemctl restart infinibay-frontend" 2>&1
        frontend_restart_status=$?
        set -e

        if [[ $frontend_restart_status -ne 0 ]]; then
            update_step 5 "Restarting frontend service" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_service_restart_failed "frontend" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        # Wait for frontend service to become active (max 30 seconds)
        update_step 6 "Waiting for frontend service" "in-progress"
        for i in {1..30}; do
            set +e
            sg lxd -c "lxc exec infinibay-frontend -- systemctl is-active --quiet infinibay-frontend" 2>/dev/null
            frontend_active=$?
            set -e

            if [[ $frontend_active -eq 0 ]]; then
                break
            fi

            if [[ $i -eq 30 ]]; then
                update_step 6 "Waiting for frontend service" "failed"
                display_rollback_notice "$BACKUP_PATH"
                error_health_check_failed "frontend" "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                exit 1
            fi

            sleep 1
        done
        update_step 6 "Waiting for frontend service" "complete"

        phase_summary "Phase 2.3: Update Frontend" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Phase 3: Verification & Cleanup
        # ========================================
        start_phase "Phase 3: Health Checks" 3
        display_time_estimate "health-check"

        # Run comprehensive health checks
        update_step 1 "Running PostgreSQL health check" "in-progress"
        update_step 2 "Running Backend health check" "in-progress"
        update_step 3 "Running Frontend health check" "in-progress"

        if ! run_all_health_checks; then
            update_step 3 "Running health checks" "failed"
            display_rollback_notice "$BACKUP_PATH"
            error_health_check_failed "system" "$BACKUP_PATH"
            rollback_to_backup "$BACKUP_PATH"
            exit 1
        fi

        update_step 1 "PostgreSQL health check" "complete"
        update_step 2 "Backend health check" "complete"
        update_step 3 "Frontend health check" "complete"

        phase_summary "Phase 3: Health Checks" "$PROGRESS_PHASE_START_TIME" "success"

        # Display success message
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║         Update Completed Successfully!                       ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}Backup available at: ${CYAN}$BACKUP_PATH${NC}"
        echo -e "${YELLOW}To rollback if issues occur: ${CYAN}./run.sh rollback $BACKUP_PATH${NC}"
        echo ""
        echo -e "For detailed help: ${CYAN}./run.sh help update${NC}"
        echo ""
        echo -e "${BLUE}Services:${NC}"
        echo -e "  Frontend: ${GREEN}http://localhost:3000${NC}"
        echo -e "  Backend:  ${GREEN}http://localhost:4000/graphql${NC}"
        echo ""
        ;;

    upgrade|ug)
        # Versioned upgrade command
        # Phase 8: Implements --list functionality
        # Phase 9: Full upgrade execution with manifest-driven steps

        # Parse options
        DRY_RUN_MODE=false
        TARGET_VERSION=""

        # Process arguments
        shift  # Remove 'upgrade' from args
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --list|-l)
                    # List available upgrades
                    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
                    echo -e "${BLUE}║         Available Infinibay Upgrades                         ║${NC}"
                    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
                    echo ""

                    CURRENT_VERSION=$(get_current_version)
                    echo -e "${BLUE}Current version:${NC} ${GREEN}$CURRENT_VERSION${NC}"
                    echo ""

                    list_available_upgrades "$SCRIPT_DIR/upgrades"
                    exit $?
                    ;;
                --dry-run|-d)
                    DRY_RUN_MODE=true
                    shift
                    ;;
                -*)
                    echo -e "${RED}Error: Unknown option: $1${NC}"
                    echo -e "${YELLOW}Usage:${NC} $0 upgrade [--dry-run|-d] <version>"
                    echo -e "${YELLOW}       ${NC} $0 upgrade --list"
                    exit 1
                    ;;
                *)
                    TARGET_VERSION="$1"
                    shift
                    ;;
            esac
        done

        # Validate version was specified
        if [[ -z "$TARGET_VERSION" ]]; then
            echo -e "${RED}Error: No upgrade version specified${NC}"
            echo -e "${YELLOW}Usage:${NC} $0 upgrade [--dry-run|-d] <version>"
            echo -e "${YELLOW}Example:${NC} $0 upgrade v0.3.0"
            echo -e "${YELLOW}Example:${NC} $0 upgrade --dry-run v0.3.0"
            echo ""
            echo -e "To see available upgrades: ${BLUE}$0 upgrade --list${NC}"
            exit 1
        fi

        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay Upgrade System                             ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        display_time_estimate "total-upgrade" "Estimated total time:"

        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
            echo ""
        fi

        # ========================================
        # Step 1: Manifest Loading & Validation
        # ========================================
        start_phase "Step 1: Loading Upgrade Manifest" 3

        UPGRADE_DIR="$SCRIPT_DIR/upgrades/$TARGET_VERSION"
        MANIFEST_PATH="$UPGRADE_DIR/manifest.yml"

        # Check if upgrade directory exists
        update_step 1 "Checking upgrade directory" "in-progress"
        if [[ ! -d "$UPGRADE_DIR" ]]; then
            update_step 1 "Checking upgrade directory" "failed"
            echo -e "${RED}Error: Upgrade directory not found: $UPGRADE_DIR${NC}"
            echo -e "${YELLOW}Available upgrades:${NC}"
            list_available_upgrades "$SCRIPT_DIR/upgrades"
            exit 1
        fi

        # Check if manifest exists
        if [[ ! -f "$MANIFEST_PATH" ]]; then
            update_step 1 "Checking upgrade directory" "failed"
            echo -e "${RED}Error: Manifest not found: $MANIFEST_PATH${NC}"
            exit 1
        fi
        update_step 1 "Checking upgrade directory" "complete"

        # Parse manifest
        update_step 2 "Parsing manifest" "in-progress"
        set +e
        parse_manifest "$MANIFEST_PATH"
        parse_exit_code=$?
        set -e

        if [[ $parse_exit_code -ne 0 ]]; then
            update_step 2 "Parsing manifest" "failed"
            echo -e "${RED}Error: Failed to parse manifest${NC}"
            exit 1
        fi
        update_step 2 "Parsing manifest" "complete"
        echo -e "${DIM}Manifest loaded: $MANIFEST_FROM_VERSION -> $MANIFEST_VERSION${NC}"

        # Validate manifest
        update_step 3 "Validating manifest structure" "in-progress"
        set +e
        validate_manifest "$MANIFEST_PATH" > /dev/null 2>&1
        validate_exit_code=$?
        set -e

        if [[ $validate_exit_code -ne 0 ]]; then
            update_step 3 "Validating manifest structure" "failed"
            echo -e "${RED}Error: Manifest validation failed${NC}"
            echo -e "${YELLOW}Run with validate_manifest to see details${NC}"
            validate_manifest "$MANIFEST_PATH"
            exit 1
        fi
        update_step 3 "Validating manifest structure" "complete"

        phase_summary "Step 1: Loading Upgrade Manifest" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Step 2: Version Compatibility Check
        # ========================================
        start_phase "Step 2: Version Compatibility Check" 1

        update_step 1 "Checking version compatibility" "in-progress"
        set +e
        check_version_compatibility "$MANIFEST_PATH"
        compat_exit_code=$?
        set -e

        if [[ $compat_exit_code -ne 0 ]]; then
            update_step 1 "Checking version compatibility" "failed"
            error_preflight_failed "version-compatibility" "Current version does not match upgrade from_version" "You may need to upgrade incrementally through intermediate versions"
            exit 1
        fi
        update_step 1 "Checking version compatibility" "complete"
        echo -e "${DIM}Version compatible: $(get_current_version) -> $MANIFEST_VERSION${NC}"

        phase_summary "Step 2: Version Compatibility Check" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Step 3: Display Upgrade Summary & Breaking Changes
        # Note: display_upgrade_summary internally calls display_breaking_changes
        # to show any breaking changes from MANIFEST_BREAKING_CHANGES array
        # ========================================
        echo -e "${BLUE}=== Step 3: Upgrade Summary & Breaking Changes ===${NC}"
        echo ""

        display_upgrade_summary "$MANIFEST_PATH"
        # Breaking changes are displayed by display_upgrade_summary via display_breaking_changes
        echo ""

        # ========================================
        # Dry Run: Display steps and exit
        # ========================================
        if [[ "$DRY_RUN_MODE" == "true" ]]; then
            echo -e "${BLUE}=== DRY RUN: Steps That Would Be Executed ===${NC}"
            echo ""

            # Display pre-flight checks
            if [[ ${#MANIFEST_PRE_FLIGHT[@]} -gt 0 ]]; then
                echo -e "${BLUE}Pre-flight Checks:${NC}"
                check_num=1
                for check_json in "${MANIFEST_PRE_FLIGHT[@]}"; do
                    check_name=$(get_manifest_field "$check_json" "name")
                    check_script=$(get_manifest_field "$check_json" "script")
                    check_required=$(get_manifest_field "$check_json" "required")
                    [[ "$check_required" == "null" ]] && check_required="true"
                    echo -e "  $check_num. ${YELLOW}$check_name${NC} (script: $check_script, required: $check_required)"
                    check_num=$((check_num + 1))
                done
                echo ""
            fi

            # Display upgrade steps
            echo -e "${BLUE}Upgrade Steps:${NC}"
            step_num=1
            for step_json in "${MANIFEST_STEPS[@]}"; do
                step_name=$(get_manifest_field "$step_json" "name")
                step_container=$(get_manifest_field "$step_json" "container")
                step_script=$(get_manifest_field "$step_json" "script")
                step_description=$(get_manifest_field "$step_json" "description")
                step_timeout=$(get_manifest_field "$step_json" "timeout")
                step_rollback=$(get_manifest_field "$step_json" "rollback_on_fail")
                [[ "$step_timeout" == "null" ]] && step_timeout="300"
                [[ "$step_rollback" == "null" ]] && step_rollback="true"
                echo -e "  $step_num. ${GREEN}$step_name${NC}"
                echo -e "     Container: $step_container"
                echo -e "     Script: $step_script"
                echo -e "     Description: $step_description"
                echo -e "     Timeout: ${step_timeout}s, Rollback on fail: $step_rollback"
                step_num=$((step_num + 1))
            done
            echo ""

            # Display validation checks
            if [[ ${#MANIFEST_VALIDATION[@]} -gt 0 ]]; then
                echo -e "${BLUE}Validation Checks:${NC}"
                val_num=1
                for check_json in "${MANIFEST_VALIDATION[@]}"; do
                    check_name=$(get_manifest_field "$check_json" "name")
                    check_script=$(get_manifest_field "$check_json" "script")
                    check_critical=$(get_manifest_field "$check_json" "critical")
                    [[ "$check_critical" == "null" ]] && check_critical="true"
                    echo -e "  $val_num. ${YELLOW}$check_name${NC} (script: $check_script, critical: $check_critical)"
                    val_num=$((val_num + 1))
                done
                echo ""
            fi

            echo -e "${YELLOW}DRY RUN: No changes were made${NC}"
            exit 0
        fi

        # ========================================
        # Step 4: User Confirmation
        # ========================================
        echo -e "${BLUE}=== Step 4: Confirmation ===${NC}"
        echo ""

        echo -e "${YELLOW}This upgrade will modify your Infinibay installation.${NC}"
        echo -e "${YELLOW}A backup will be created before proceeding.${NC}"
        echo ""

        read -p "Continue with upgrade to $MANIFEST_VERSION? (y/N) " -n 1 -r
        echo ""

        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Upgrade cancelled by user${NC}"
            exit 2
        fi

        echo ""

        # ========================================
        # Step 5: Pre-flight Checks Execution
        # ========================================
        if [[ ${#MANIFEST_PRE_FLIGHT[@]} -gt 0 ]]; then
            PREFLIGHT_TOTAL=${#MANIFEST_PRE_FLIGHT[@]}
            start_phase "Step 5: Pre-flight Checks" "$PREFLIGHT_TOTAL"

            PREFLIGHT_CURRENT=1
            for check_json in "${MANIFEST_PRE_FLIGHT[@]}"; do
                check_name=$(get_manifest_field "$check_json" "name")
                check_script=$(get_manifest_field "$check_json" "script")
                check_required=$(get_manifest_field "$check_json" "required")
                check_message=$(get_manifest_field "$check_json" "message")
                [[ "$check_required" == "null" ]] && check_required="true"

                script_path="$UPGRADE_DIR/$check_script"

                update_step "$PREFLIGHT_CURRENT" "$check_name" "in-progress"

                if [[ ! -f "$script_path" ]]; then
                    if [[ "$check_required" == "true" ]]; then
                        update_step "$PREFLIGHT_CURRENT" "$check_name" "failed"
                        error_preflight_failed "pre-flight-script" "Script not found: $check_script" "Ensure the upgrade manifest references valid scripts"
                        exit 1
                    else
                        update_step "$PREFLIGHT_CURRENT" "$check_name (script missing)" "skipped"
                        PREFLIGHT_CURRENT=$((PREFLIGHT_CURRENT + 1))
                        continue
                    fi
                fi

                # Execute pre-flight script
                set +e
                bash "$script_path"
                check_exit_code=$?
                set -e

                if [[ $check_exit_code -ne 0 ]]; then
                    if [[ "$check_required" == "true" ]]; then
                        update_step "$PREFLIGHT_CURRENT" "$check_name" "failed"
                        error_preflight_failed "pre-flight-check" "Pre-flight check '$check_name' failed" "${check_message:-Check the script output above for details}"
                        exit 1
                    else
                        update_step "$PREFLIGHT_CURRENT" "$check_name (non-critical)" "skipped"
                        if [[ -n "$check_message" ]] && [[ "$check_message" != "null" ]]; then
                            echo -e "${DIM}$check_message${NC}"
                        fi
                    fi
                else
                    update_step "$PREFLIGHT_CURRENT" "$check_name" "complete"
                fi
                PREFLIGHT_CURRENT=$((PREFLIGHT_CURRENT + 1))
            done

            phase_summary "Step 5: Pre-flight Checks" "$PROGRESS_PHASE_START_TIME" "success"
        fi

        # ========================================
        # Step 6: Backup Creation
        # ========================================
        start_phase "Step 6: Creating Backup" 2
        display_time_estimate "backup"

        # Create backup using backup.sh library (same pattern as update command)
        update_step 1 "Creating system backup" "in-progress"
        set +e
        BACKUP_OUTPUT=$(create_backup "upgrade_${MANIFEST_FROM_VERSION}_to_${MANIFEST_VERSION}" 2>&1)
        backup_exit_code=$?
        set -e

        if [[ $backup_exit_code -ne 0 ]]; then
            update_step 1 "Creating system backup" "failed"
            error_preflight_failed "backup-writable" "Backup creation failed" "Check disk space and permissions on /data/backups"
            echo "$BACKUP_OUTPUT"
            exit 1
        fi
        update_step 1 "Creating system backup" "complete"

        # Extract backup path from output
        update_step 2 "Validating backup" "in-progress"
        BACKUP_PATH=$(echo "$BACKUP_OUTPUT" | grep "Location:" | sed 's/.*Location: //' | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n' | xargs)

        if [[ -z "$BACKUP_PATH" ]]; then
            update_step 2 "Validating backup" "failed"
            echo -e "${RED}Failed to extract backup path from create_backup output${NC}"
            echo -e "${RED}This is a critical error - cannot proceed without valid backup${NC}"
            echo ""
            echo -e "${YELLOW}create_backup output:${NC}"
            echo "$BACKUP_OUTPUT"
            exit 1
        fi

        # Validate backup path exists in postgres container
        set +e
        sg lxd -c "lxc exec infinibay-postgres -- test -d '$BACKUP_PATH'" 2>/dev/null
        backup_dir_exists=$?
        set -e

        if [[ $backup_dir_exists -ne 0 ]]; then
            update_step 2 "Validating backup" "failed"
            echo -e "${RED}Backup path does not exist in postgres container: $BACKUP_PATH${NC}"
            echo -e "${RED}Cannot proceed without valid backup${NC}"
            exit 1
        fi
        update_step 2 "Validating backup" "complete"
        echo -e "${GREEN}Backup location: ${CYAN}$BACKUP_PATH${NC}"

        phase_summary "Step 6: Creating Backup" "$PROGRESS_PHASE_START_TIME" "success"

        # ========================================
        # Step 7: Execute Upgrade Steps
        # ========================================
        STEP7_START=$(date +%s)
        start_phase "Execute Upgrade Steps" "${#MANIFEST_STEPS[@]}"

        total_steps=${#MANIFEST_STEPS[@]}
        current_step=1

        for step_json in "${MANIFEST_STEPS[@]}"; do
            step_name=$(get_manifest_field "$step_json" "name")
            step_container=$(get_manifest_field "$step_json" "container")
            step_script=$(get_manifest_field "$step_json" "script")
            step_description=$(get_manifest_field "$step_json" "description")
            step_timeout=$(get_manifest_field "$step_json" "timeout")
            step_rollback_on_fail=$(get_manifest_field "$step_json" "rollback_on_fail")

            # Set defaults
            [[ "$step_timeout" == "null" ]] && step_timeout="300"
            [[ "$step_rollback_on_fail" == "null" ]] && step_rollback_on_fail="true"

            update_step "$current_step" "$step_name" "in-progress"
            echo -e "  ${DIM}$step_description${NC}"

            script_path="$UPGRADE_DIR/$step_script"

            # Check if script exists
            if [[ ! -f "$script_path" ]]; then
                update_step "$current_step" "$step_name" "failed"
                error_migration_failed "upgrade" "$step_exit_code" "Script not found: $step_script"
                if [[ "$step_rollback_on_fail" == "true" ]]; then
                    display_rollback_notice "$BACKUP_PATH"
                    set +e
                    rollback_to_backup "$BACKUP_PATH"
                    rollback_exit_code=$?
                    set -e
                    if [[ $rollback_exit_code -eq 0 ]]; then
                        phase_summary "Execute Upgrade Steps" "$STEP7_START" "failed"
                        echo -e "${GREEN}Rollback completed successfully${NC}"
                    else
                        error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                    fi
                fi
                exit 1
            fi

            # Push script to container temp location
            set +e
            sg lxd -c "lxc file push '$script_path' '$step_container/tmp/upgrade_step.sh'" 2>&1
            push_exit_code=$?
            set -e

            if [[ $push_exit_code -ne 0 ]]; then
                update_step "$current_step" "$step_name" "failed"
                error_migration_failed "upgrade" "$push_exit_code" "Failed to copy script to container $step_container"
                if [[ "$step_rollback_on_fail" == "true" ]]; then
                    display_rollback_notice "$BACKUP_PATH"
                    set +e
                    rollback_to_backup "$BACKUP_PATH"
                    rollback_exit_code=$?
                    set -e
                    if [[ $rollback_exit_code -eq 0 ]]; then
                        phase_summary "Execute Upgrade Steps" "$STEP7_START" "failed"
                        echo -e "${GREEN}Rollback completed successfully${NC}"
                    else
                        error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                    fi
                fi
                exit 1
            fi

            # Make script executable
            sg lxd -c "lxc exec $step_container -- chmod +x /tmp/upgrade_step.sh" 2>&1

            # Execute script in container with enforced timeout
            set +e
            # Use timeout utility to enforce step_timeout; exit code 124 indicates timeout
            timeout "${step_timeout}s" sg lxd -c "lxc exec $step_container -- bash /tmp/upgrade_step.sh" 2>&1
            step_exit_code=$?
            set -e

            # Clean up temp script
            sg lxd -c "lxc exec $step_container -- rm -f /tmp/upgrade_step.sh" 2>/dev/null || true

            # Check for timeout (exit code 124) or other failure
            if [[ $step_exit_code -eq 124 ]]; then
                update_step "$current_step" "$step_name" "failed"
                error_migration_failed "upgrade" "124" "Step '$step_name' timed out after ${step_timeout}s"
                if [[ "$step_rollback_on_fail" == "true" ]]; then
                    display_rollback_notice "$BACKUP_PATH"
                    set +e
                    rollback_to_backup "$BACKUP_PATH"
                    rollback_exit_code=$?
                    set -e
                    if [[ $rollback_exit_code -eq 0 ]]; then
                        phase_summary "Execute Upgrade Steps" "$STEP7_START" "failed"
                        echo -e "${GREEN}Rollback completed successfully${NC}"
                    else
                        error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                    fi
                    exit 1
                else
                    echo -e "${YELLOW}Warning: Step timed out but rollback_on_fail=false, continuing...${NC}"
                fi
            elif [[ $step_exit_code -ne 0 ]]; then
                update_step "$current_step" "$step_name" "failed"
                error_migration_failed "upgrade" "$step_exit_code" "Step '$step_name' failed"
                if [[ "$step_rollback_on_fail" == "true" ]]; then
                    display_rollback_notice "$BACKUP_PATH"
                    set +e
                    rollback_to_backup "$BACKUP_PATH"
                    rollback_exit_code=$?
                    set -e
                    if [[ $rollback_exit_code -eq 0 ]]; then
                        phase_summary "Execute Upgrade Steps" "$STEP7_START" "failed"
                        echo -e "${GREEN}Rollback completed successfully${NC}"
                    else
                        error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                    fi
                    exit 1
                else
                    echo -e "${YELLOW}Warning: Step failed but rollback_on_fail=false, continuing...${NC}"
                fi
            else
                update_step "$current_step" "$step_name" "complete"
            fi

            current_step=$((current_step + 1))
        done

        phase_summary "Execute Upgrade Steps" "$STEP7_START" "success"

        # ========================================
        # Step 8: Post-Upgrade Validation
        # ========================================
        if [[ ${#MANIFEST_VALIDATION[@]} -gt 0 ]]; then
            STEP8_START=$(date +%s)
            start_phase "Post-Upgrade Validation" "${#MANIFEST_VALIDATION[@]}"

            validation_step=1
            for check_json in "${MANIFEST_VALIDATION[@]}"; do
                check_name=$(get_manifest_field "$check_json" "name")
                check_script=$(get_manifest_field "$check_json" "script")
                check_critical=$(get_manifest_field "$check_json" "critical")
                [[ "$check_critical" == "null" ]] && check_critical="true"

                script_path="$UPGRADE_DIR/$check_script"

                update_step "$validation_step" "$check_name" "in-progress"

                if [[ ! -f "$script_path" ]]; then
                    if [[ "$check_critical" == "true" ]]; then
                        update_step "$validation_step" "$check_name" "failed"
                        error_preflight_failed "validation" "Script not found: $check_script"
                        display_rollback_notice "$BACKUP_PATH"
                        set +e
                        rollback_to_backup "$BACKUP_PATH"
                        rollback_exit_code=$?
                        set -e
                        if [[ $rollback_exit_code -eq 0 ]]; then
                            phase_summary "Post-Upgrade Validation" "$STEP8_START" "failed"
                            echo -e "${GREEN}Rollback completed successfully${NC}"
                        else
                            error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                        fi
                        exit 1
                    else
                        update_step "$validation_step" "$check_name" "skipped"
                        validation_step=$((validation_step + 1))
                        continue
                    fi
                fi

                # Execute validation script
                set +e
                bash "$script_path"
                validation_exit_code=$?
                set -e

                if [[ $validation_exit_code -ne 0 ]]; then
                    if [[ "$check_critical" == "true" ]]; then
                        update_step "$validation_step" "$check_name" "failed"
                        error_preflight_failed "validation" "Critical validation '$check_name' failed with exit code $validation_exit_code"
                        display_rollback_notice "$BACKUP_PATH"
                        set +e
                        rollback_to_backup "$BACKUP_PATH"
                        rollback_exit_code=$?
                        set -e
                        if [[ $rollback_exit_code -eq 0 ]]; then
                            phase_summary "Post-Upgrade Validation" "$STEP8_START" "failed"
                            echo -e "${GREEN}Rollback completed successfully${NC}"
                        else
                            error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                        fi
                        exit 1
                    else
                        update_step "$validation_step" "$check_name" "skipped"
                        echo -e "  ${YELLOW}Non-critical validation failed, continuing...${NC}"
                    fi
                else
                    update_step "$validation_step" "$check_name" "complete"
                fi

                validation_step=$((validation_step + 1))
            done

            phase_summary "Post-Upgrade Validation" "$STEP8_START" "success"
        fi

        # ========================================
        # Step 9: Health Checks (optional integration)
        # ========================================
        STEP9_START=$(date +%s)
        start_phase "Health Checks" 1

        # Run health checks if available
        set +e
        if type run_all_health_checks &>/dev/null; then
            update_step 1 "Running health checks" "in-progress"
            run_all_health_checks
            health_exit_code=$?
            if [[ $health_exit_code -ne 0 ]]; then
                update_step 1 "Running health checks" "failed"
                error_health_check_failed "services" "$health_exit_code"
                display_rollback_notice "$BACKUP_PATH"
                rollback_to_backup "$BACKUP_PATH"
                rollback_exit_code=$?
                if [[ $rollback_exit_code -eq 0 ]]; then
                    phase_summary "Health Checks" "$STEP9_START" "failed"
                    echo -e "${GREEN}Rollback completed successfully${NC}"
                else
                    error_rollback_failed "$rollback_exit_code" "$BACKUP_PATH"
                fi
                exit 1
            fi
            update_step 1 "Running health checks" "complete"
        else
            update_step 1 "Health checks" "skipped"
            echo -e "  ${DIM}Health checks not available${NC}"
        fi
        set -e

        phase_summary "Health Checks" "$STEP9_START" "success"

        # ========================================
        # Step 10: Update Version File
        # ========================================
        STEP10_START=$(date +%s)
        start_phase "Update Version" 1

        # Track if version update fails (partial failure - upgrade ran but version not recorded)
        VERSION_UPDATE_FAILED=false

        update_step 1 "Updating version to $MANIFEST_VERSION" "in-progress"

        set +e
        set_current_version "$MANIFEST_VERSION"
        version_exit_code=$?
        set -e

        if [[ $version_exit_code -ne 0 ]]; then
            VERSION_UPDATE_FAILED=true
            update_step 1 "Updating version to $MANIFEST_VERSION" "failed"
            echo ""
            echo -e "${RED}The upgrade steps completed successfully, but the version file could not be updated.${NC}"
            echo -e "${YELLOW}To fix manually, run:${NC}"
            echo -e "  echo '$MANIFEST_VERSION' > $SCRIPT_DIR/upgrades/current_version.txt"
            phase_summary "Update Version" "$STEP10_START" "partial"
        else
            update_step 1 "Updating version to $MANIFEST_VERSION" "complete"
            phase_summary "Update Version" "$STEP10_START" "success"
        fi

        # ========================================
        # Step 11: Display Post-Upgrade Notes
        # ========================================
        if [[ -f "$UPGRADE_DIR/README.md" ]]; then
            echo ""
            echo -e "${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
            echo -e "${BLUE}│${NC} ${BOLD}Post-Upgrade Notes${NC}"
            echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
            echo ""
            cat "$UPGRADE_DIR/README.md"
            echo ""
        fi

        # ========================================
        # Final Status Message
        # ========================================
        TOTAL_ELAPSED=$(display_elapsed_time "$UPGRADE_START_TIME")

        if [[ "$VERSION_UPDATE_FAILED" == "true" ]]; then
            echo ""
            echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║         Upgrade Completed with Partial Failure               ║${NC}"
            echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Upgrade steps from ${MANIFEST_FROM_VERSION} to ${MANIFEST_VERSION} completed,${NC}"
            echo -e "${YELLOW}but the version file failed to update.${NC}"
            echo ""
            echo -e "${RED}ACTION REQUIRED:${NC} Update the version file manually:"
            echo -e "  echo '$MANIFEST_VERSION' > $SCRIPT_DIR/upgrades/current_version.txt"
            echo ""
            echo -e "${DIM}Total time: ${TOTAL_ELAPSED}${NC}"
            echo -e "${BLUE}Backup available at:${NC} $BACKUP_PATH"
            echo -e "${YELLOW}To rollback if issues occur:${NC} ${BLUE}./run.sh rollback $BACKUP_PATH${NC}"
            echo ""
            echo -e "${BLUE}Services:${NC}"
            echo -e "  Frontend: ${GREEN}http://localhost:3000${NC}"
            echo -e "  Backend:  ${GREEN}http://localhost:4000/graphql${NC}"
            echo ""
            # Exit with non-zero to indicate partial failure
            exit 3
        else
            echo ""
            echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║         Upgrade Completed Successfully!                      ║${NC}"
            echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${GREEN}Upgraded from ${MANIFEST_FROM_VERSION} to ${MANIFEST_VERSION}${NC}"
            echo ""
            echo -e "${DIM}Total time: ${TOTAL_ELAPSED}${NC}"
            echo -e "${BLUE}Backup available at:${NC} $BACKUP_PATH"
            echo -e "${YELLOW}To rollback if issues occur:${NC} ${BLUE}./run.sh rollback $BACKUP_PATH${NC}"
            echo ""
            echo -e "${BLUE}Services:${NC}"
            echo -e "  Frontend: ${GREEN}http://localhost:3000${NC}"
            echo -e "  Backend:  ${GREEN}http://localhost:4000/graphql${NC}"
            echo ""
        fi
        ;;

    help-update|help_update)
        # Display detailed help for update command
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay Update Command - Detailed Help             ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}Purpose:${NC}"
        echo -e "  Atomically update all Infinibay repositories (lxd, libvirt-node, backend, frontend)"
        echo -e "  to their latest versions from the main branch. Includes automatic backup and"
        echo -e "  rollback on failure."
        echo ""
        echo -e "${BLUE}Usage:${NC}"
        echo -e "  $0 update"
        echo -e "  $0 u        # Shortcut"
        echo -e "  $0 up       # Shortcut"
        echo ""
        echo -e "${BLUE}What It Does:${NC}"
        echo -e "  ${CYAN}Phase 0:${NC} Self-update LXD scripts (re-executes if run.sh changed)"
        echo -e "  ${CYAN}Phase 1:${NC} Create timestamped backup (database + git state)"
        echo -e "  ${CYAN}Phase 2:${NC} Update repositories in order:"
        echo -e "    1. libvirt-node: Pull → Build Rust → Package → Copy to backend"
        echo -e "    2. backend: Pull → Install deps → Build → Migrate DB → Restart"
        echo -e "    3. frontend: Pull → Install deps → Codegen → Build → Restart"
        echo -e "  ${CYAN}Phase 3:${NC} Run health checks (postgres, backend, frontend)"
        echo ""
        echo -e "${YELLOW}When to Use:${NC}"
        echo -e "  • Regular updates with non-breaking changes"
        echo -e "  • Pulling latest bug fixes and features"
        echo -e "  • Development/testing environments"
        echo -e "  • When you want to stay on the bleeding edge"
        echo ""
        echo -e "${YELLOW}When NOT to Use:${NC}"
        echo -e "  • Major version upgrades (use ${BLUE}upgrade${NC} command instead)"
        echo -e "  • Breaking changes requiring manual intervention"
        echo -e "  • Production environments (use ${BLUE}upgrade${NC} with tested versions)"
        echo ""
        echo -e "${BLUE}Automatic Rollback:${NC}"
        echo -e "  If any step fails, the system automatically rolls back to the backup:"
        echo -e "  • Restores database from pg_dump"
        echo -e "  • Resets git repositories to previous commits"
        echo -e "  • Rebuilds all code from scratch"
        echo -e "  • Restarts services"
        echo -e "  • Verifies system health"
        echo ""
        echo -e "${BLUE}Estimated Duration:${NC}"
        echo -e "  • Backup: 1-2 minutes"
        echo -e "  • libvirt-node: 5-10 minutes (Rust compilation)"
        echo -e "  • backend: 2-3 minutes"
        echo -e "  • frontend: 1-2 minutes"
        echo -e "  • Health checks: 1-2 minutes"
        echo -e "  ${GREEN}Total: 10-20 minutes${NC}"
        echo ""
        echo -e "${BLUE}Examples:${NC}"
        echo -e "  ${GREEN}$0 update${NC}              # Run full update"
        echo -e "  ${GREEN}$0 u${NC}                   # Same, using shortcut"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo -e "  • If update fails, check error message for specific guidance"
        echo -e "  • Backup is preserved at /data/backups/update_<timestamp>"
        echo -e "  • Manual rollback: $0 rollback /data/backups/update_<timestamp>"
        echo -e "  • Check logs: $0 logs <container-name>"
        echo -e "  • For more help: See ${BLUE}lxd/UPDATE_GUIDE.md${NC}"
        echo ""
        ;;

    help-upgrade|help_upgrade)
        # Display detailed help for upgrade command
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay Upgrade Command - Detailed Help            ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}Purpose:${NC}"
        echo -e "  Perform versioned upgrades to specific Infinibay releases using manifest-driven"
        echo -e "  orchestration. Handles breaking changes, custom migrations, and coordinated"
        echo -e "  multi-repository updates."
        echo ""
        echo -e "${BLUE}Usage:${NC}"
        echo -e "  $0 upgrade <version>           # Upgrade to specific version"
        echo -e "  $0 upgrade --list              # List available upgrades"
        echo -e "  $0 upgrade --dry-run <version> # Preview upgrade without changes"
        echo -e "  $0 ug <version>                # Shortcut"
        echo ""
        echo -e "${BLUE}What It Does:${NC}"
        echo -e "  1. Load and validate upgrade manifest (manifest.yml)"
        echo -e "  2. Check version compatibility (from_version matches current)"
        echo -e "  3. Display upgrade summary and breaking changes"
        echo -e "  4. Request user confirmation"
        echo -e "  5. Run pre-flight checks (custom per version)"
        echo -e "  6. Create backup (tagged with version transition)"
        echo -e "  7. Execute upgrade steps in order (custom scripts per version)"
        echo -e "  8. Run validation checks"
        echo -e "  9. Run health checks"
        echo -e "  10. Update current_version.txt"
        echo -e "  11. Display post-upgrade notes"
        echo ""
        echo -e "${YELLOW}When to Use:${NC}"
        echo -e "  • Major version upgrades (e.g., v0.2.0 → v0.3.0)"
        echo -e "  • Breaking changes requiring manual steps"
        echo -e "  • Production environments (tested, stable releases)"
        echo -e "  • Coordinated multi-repo changes"
        echo -e "  • Custom data migrations or transformations"
        echo ""
        echo -e "${YELLOW}When NOT to Use:${NC}"
        echo -e "  • Regular updates (use ${BLUE}update${NC} command instead)"
        echo -e "  • Development/testing (${BLUE}update${NC} is faster)"
        echo -e "  • Skipping versions (upgrade incrementally)"
        echo ""
        echo -e "${BLUE}Upgrade Manifests:${NC}"
        echo -e "  Located in: ${CYAN}lxd/upgrades/<version>/manifest.yml${NC}"
        echo -e "  Contains:"
        echo -e "    • Version compatibility requirements"
        echo -e "    • Pre-flight checks (custom validation)"
        echo -e "    • Upgrade steps (scripts to execute)"
        echo -e "    • Validation checks (post-upgrade verification)"
        echo -e "    • Breaking changes documentation"
        echo -e "    • Post-upgrade notes"
        echo ""
        echo -e "${BLUE}Automatic Rollback:${NC}"
        echo -e "  If any critical step fails:"
        echo -e "  • Stops upgrade immediately"
        echo -e "  • Restores database from backup"
        echo -e "  • Resets git repositories to previous commits"
        echo -e "  • Rebuilds all code"
        echo -e "  • Restarts services"
        echo -e "  • Verifies system health"
        echo ""
        echo -e "${BLUE}Options:${NC}"
        echo -e "  ${GREEN}--list, -l${NC}       List available upgrades with compatibility info"
        echo -e "  ${GREEN}--dry-run, -d${NC}    Preview upgrade steps without making changes"
        echo ""
        echo -e "${BLUE}Examples:${NC}"
        echo -e "  ${GREEN}$0 upgrade --list${NC}              # See available upgrades"
        echo -e "  ${GREEN}$0 upgrade --dry-run v0.3.0${NC}    # Preview v0.3.0 upgrade"
        echo -e "  ${GREEN}$0 upgrade v0.3.0${NC}              # Upgrade to v0.3.0"
        echo -e "  ${GREEN}$0 ug v0.3.0${NC}                   # Same, using shortcut"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo -e "  • If upgrade fails, check error message for specific guidance"
        echo -e "  • Backup is preserved at /data/backups/upgrade_<from>_to_<to>_<timestamp>"
        echo -e "  • Manual rollback: $0 rollback /data/backups/upgrade_..."
        echo -e "  • Check upgrade logs in upgrade directory"
        echo -e "  • Review breaking changes: cat lxd/upgrades/<version>/README.md"
        echo -e "  • For more help: See ${BLUE}lxd/UPDATE_GUIDE.md${NC}"
        echo ""
        ;;

    help-join|help_join)
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay Join Command - Detailed Help              ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}Purpose:${NC}"
        echo -e "  Onboard THIS host as a compute node of an existing Infinibay master"
        echo -e "  cluster, using the SAS-verified mTLS enrollment flow (\"double"
        echo -e "  verification\")."
        echo ""
        echo -e "${BLUE}Usage:${NC}"
        echo -e "  $0 join <master-url> <token> [node-name]"
        echo -e "  $0 join auto <token> [node-name]      # discover the master via mDNS"
        echo -e "  $0 jn <master-url> <token>             # shortcut"
        echo ""
        echo -e "${BLUE}Arguments:${NC}"
        echo -e "  ${GREEN}master-url${NC}   The master's HTTP endpoint, e.g. http://master:4000"
        echo -e "               (or 'auto' to discover it on the LAN via mDNS)"
        echo -e "  ${GREEN}token${NC}        The cluster bootstrap token (INFINIBAY_CLUSTER_TOKEN on the master)"
        echo -e "  ${GREEN}node-name${NC}    This node's name (default: hostname)"
        echo ""
        echo -e "${BLUE}What It Does:${NC}"
        echo -e "  1. Runs ${CYAN}npm run agent:join${NC} in the agent container"
        echo -e "  2. Prints a 6-digit PAIRING CODE for this node"
        echo -e "  3. You compare it with the code shown for the node in the master's"
        echo -e "     Infrastructure UI and APPROVE it there (a mismatch = possible MITM)"
        echo -e "  4. The master signs this node's client certificate; it is written to"
        echo -e "     ${CYAN}INFINIBAY_CERT_DIR${NC} (default /opt/infinibay/certs)"
        echo ""
        echo -e "${YELLOW}After joining — start the node agent in mTLS mode${NC} (set, then ${GREEN}npm run agent:heartbeat${NC}):"
        echo -e "  ${CYAN}INFINIBAY_CLUSTER_MTLS=1${NC}"
        echo -e "  ${CYAN}MASTER_CLUSTER_URL=https://<master-host>:4433${NC}"
        echo -e "  ${CYAN}INFINIBAY_MASTER_CN=<the master's node name>${NC}"
        echo ""
        echo -e "${BLUE}Environment overrides:${NC}"
        echo -e "  ${GREEN}INFINIBAY_AGENT_CONTAINER${NC}   Agent container name (default: infinibay-backend)"
        echo ""
        echo -e "${BLUE}Examples:${NC}"
        echo -e "  ${GREEN}$0 join http://master:4000 s3cr3t-token${NC}"
        echo -e "  ${GREEN}$0 join http://10.0.0.5:4000 s3cr3t-token worker-1${NC}"
        echo -e "  ${GREEN}$0 join auto s3cr3t-token${NC}"
        echo ""
        ;;

    help|--help|-h)
        # Note: 'help <subcommand>' is normalized to 'help-<subcommand>' at script top
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
        echo -e "  ${GREEN}status${NC}                      s           Show container status"
        echo -e "  ${GREEN}stop${NC} [options]             st, sto     Gracefully stop all containers in reverse order"
        echo -e "    Options: --force              Force stop without waiting"
        echo -e "             --check-vms          Warn if VMs are running"
        echo -e "  ${GREEN}update${NC}                      u, up       Update all Infinibay repositories atomically"
        echo -e "    ${YELLOW}Note:${NC} Includes automatic backup and rollback on failure"
        echo -e "    ${YELLOW}Updates:${NC} libvirt-node → backend → frontend"
        echo -e "    ${CYAN}Detailed help:${NC} $0 help update"
        echo -e "  ${GREEN}upgrade${NC} <version>          ug          Upgrade to a specific Infinibay version"
        echo -e "    Options: --list, -l           List available upgrades"
        echo -e "             --dry-run, -d        Preview upgrade without making changes"
        echo -e "    ${YELLOW}Example:${NC} $0 upgrade v0.3.0"
        echo -e "    ${YELLOW}Example:${NC} $0 upgrade --dry-run v0.3.0"
        echo -e "    ${YELLOW}Note:${NC} Includes automatic backup and rollback on failure"
        echo -e "    ${CYAN}Detailed help:${NC} $0 help upgrade"
        echo -e "  ${GREEN}backup${NC}                      b, bak      Manage system backups"
        echo -e "    Options: (none)               Create manual backup"
        echo -e "             --label <text>       Create manual backup with custom label"
        echo -e "             --list, -l           List all backups with type and retention info"
        echo -e "             --clean, -c          Remove old backups per retention policy"
        echo -e "             --enable-schedule    Enable daily automatic backups (cron)"
        echo -e "             --disable-schedule   Disable automatic backups"
        echo -e "    ${YELLOW}Retention:${NC} manual (never), update/upgrade (30d), scheduled (7d or last 10)"
        echo -e "  ${GREEN}setup-profiles${NC}              sp          Generate and update LXD profiles only"
        echo -e "  ${GREEN}join${NC} <master> <token>      jn          Onboard this host as a cluster compute node"
        echo -e "    ${YELLOW}Note:${NC} SAS-verified mTLS enrollment; approve the pairing code in the master UI"
        echo -e "    ${CYAN}Detailed help:${NC} $0 help join"
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
        echo -e "  ${GREEN}$0 u${NC}                   # Update all repositories"
        echo -e "  ${GREEN}$0 upgrade --list${NC}      # List available upgrades"
        echo -e "  ${GREEN}$0 upgrade v0.3.0${NC}      # Upgrade to version 0.3.0"
        echo -e "  ${GREEN}$0 upgrade -d v0.3.0${NC}   # Preview upgrade (dry-run)"
        echo -e "  ${GREEN}$0 backup${NC}              # Create manual backup"
        echo -e "  ${GREEN}$0 backup --label test${NC} # Create backup with custom label"
        echo -e "  ${GREEN}$0 backup --list${NC}       # List all backups"
        echo -e "  ${GREEN}$0 backup --enable-schedule${NC}  # Enable daily backups"
        echo -e "  ${GREEN}$0 e backend bash${NC}      # Enter backend container"
        echo -e "  ${GREEN}$0 lo postgres${NC}         # View postgres logs"
        echo -e "  ${GREEN}$0 stop --check-vms${NC}    # Stop containers with VM warning"
        echo -e "  ${GREEN}$0 d${NC}                   # Destroy everything"
        echo ""
        echo -e "${BLUE}Container Names:${NC}"
        echo -e "  postgres, backend, frontend"
        echo ""
        echo -e "${GREEN}After setup, access:${NC}"
        echo -e "  Frontend: ${BLUE}http://localhost:3000${NC}"
        echo -e "  Backend:  ${BLUE}http://localhost:4000/graphql${NC}"
        ;;

    backup|b|bak)
        # Backup command - Create, list, and manage system backups
        #
        # Options:
        #   (none)           - Create manual backup with auto-generated label
        #   --label <text>   - Create manual backup with custom label
        #   --list           - List all backups
        #   --clean          - Apply retention policy to remove old backups
        #   --enable-schedule  - Enable scheduled backups via cron
        #   --disable-schedule - Disable scheduled backups
        #   --scheduled      - Internal: used by cron job (not documented in help)

        # Parse options
        shift
        BACKUP_LABEL=""
        DO_LIST=false
        DO_CLEAN=false
        DO_ENABLE_SCHEDULE=false
        DO_DISABLE_SCHEDULE=false
        DO_SCHEDULED=false

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --label|-L)
                    if [[ -z "$2" ]] || [[ "$2" == --* ]]; then
                        echo -e "${RED}Error: --label requires a value${NC}"
                        exit 1
                    fi
                    BACKUP_LABEL="$2"
                    shift 2
                    ;;
                --list|-l)
                    DO_LIST=true
                    shift
                    ;;
                --clean|-c)
                    DO_CLEAN=true
                    shift
                    ;;
                --enable-schedule)
                    DO_ENABLE_SCHEDULE=true
                    shift
                    ;;
                --disable-schedule)
                    DO_DISABLE_SCHEDULE=true
                    shift
                    ;;
                --scheduled)
                    DO_SCHEDULED=true
                    shift
                    ;;
                *)
                    echo -e "${RED}Error: Unknown option: $1${NC}"
                    echo -e "Usage: $0 backup [--label <text>] [--list] [--clean]"
                    echo -e "       $0 backup --enable-schedule"
                    echo -e "       $0 backup --disable-schedule"
                    exit 1
                    ;;
            esac
        done

        # Validate conflicting options
        opt_count=0
        [[ "$DO_LIST" == "true" ]] && opt_count=$((opt_count + 1))
        [[ "$DO_CLEAN" == "true" ]] && opt_count=$((opt_count + 1))
        [[ "$DO_ENABLE_SCHEDULE" == "true" ]] && opt_count=$((opt_count + 1))
        [[ "$DO_DISABLE_SCHEDULE" == "true" ]] && opt_count=$((opt_count + 1))
        [[ "$DO_SCHEDULED" == "true" ]] && opt_count=$((opt_count + 1))

        if [[ $opt_count -gt 1 ]]; then
            echo -e "${RED}Error: Cannot combine --list, --clean, --enable-schedule, --disable-schedule${NC}"
            exit 1
        fi

        if [[ -n "$BACKUP_LABEL" ]] && [[ $opt_count -gt 0 ]]; then
            echo -e "${RED}Error: --label cannot be combined with --list, --clean, or schedule options${NC}"
            exit 1
        fi

        # Check if backup functionality is enabled
        if [[ "$BACKUP_ENABLED" != "true" ]]; then
            echo -e "${RED}Error: Backup functionality is disabled${NC}"
            echo -e "${YELLOW}Hint: Set BACKUP_ENABLED=true in backup.conf${NC}"
            exit 1
        fi

        # Handle --list option
        if [[ "$DO_LIST" == "true" ]]; then
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║         Infinibay Backup List                                ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            list_backups
            exit $?
        fi

        # Handle --clean option
        if [[ "$DO_CLEAN" == "true" ]]; then
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║         Infinibay Backup Cleanup                             ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}This will delete old backups according to retention policy:${NC}"
            echo -e "  • ${BLUE}Manual${NC} backups: never deleted"
            echo -e "  • ${GREEN}Update/Upgrade${NC} backups: deleted after ${BACKUP_UPDATE_RETENTION_DAYS} days"
            echo -e "  • ${CYAN}Scheduled${NC} backups: deleted after ${BACKUP_RETENTION_DAYS} days or keep last ${BACKUP_RETENTION_COUNT}"
            echo ""
            read -p "Continue? (y/N) " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Cleanup cancelled${NC}"
                exit 2
            fi
            echo ""
            cleanup_old_backups
            exit $?
        fi

        # Handle --enable-schedule option
        if [[ "$DO_ENABLE_SCHEDULE" == "true" ]]; then
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║         Enable Scheduled Backups                             ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            # Check if cron job already exists
            if crontab -l 2>/dev/null | grep -q "run.sh backup --scheduled"; then
                echo -e "${YELLOW}Scheduled backups are already enabled${NC}"
                echo ""
                echo -e "${BLUE}Current cron entry:${NC}"
                crontab -l 2>/dev/null | grep "run.sh backup"
                exit 0
            fi

            # Add cron entry
            echo -e "${BLUE}Adding cron job for scheduled backups...${NC}"
            echo -e "${BLUE}Schedule: ${GREEN}$BACKUP_SCHEDULE${NC}"
            echo ""

            # Build the cron command
            cron_cmd="$BACKUP_SCHEDULE cd $SCRIPT_DIR && ./run.sh backup --scheduled >> /tmp/infinibay-backup-scheduled.log 2>&1"

            # Add to crontab
            (crontab -l 2>/dev/null | grep -v "run.sh backup"; echo "# Infinibay scheduled backup"; echo "$cron_cmd") | crontab -

            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}Scheduled backups enabled successfully!${NC}"
                echo ""
                echo -e "${BLUE}Cron entry added:${NC}"
                echo -e "  $cron_cmd"
                echo ""
                echo -e "${YELLOW}Notes:${NC}"
                echo -e "  • Logs will be written to: /tmp/infinibay-backup-scheduled.log"
                echo -e "  • Ensure containers are running at scheduled time"
                echo -e "  • To disable: $0 backup --disable-schedule"
            else
                echo -e "${RED}Failed to add cron entry${NC}"
                exit 1
            fi
            exit 0
        fi

        # Handle --disable-schedule option
        if [[ "$DO_DISABLE_SCHEDULE" == "true" ]]; then
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║         Disable Scheduled Backups                            ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            # Check if cron job exists
            if ! crontab -l 2>/dev/null | grep -q "run.sh backup"; then
                echo -e "${YELLOW}Scheduled backups are not enabled${NC}"
                exit 0
            fi

            # Remove cron entry
            echo -e "${BLUE}Removing cron job for scheduled backups...${NC}"

            # Remove both the comment and the cron entry
            crontab -l 2>/dev/null | grep -v "run.sh backup" | grep -v "# Infinibay scheduled backup" | crontab -

            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}Scheduled backups disabled successfully!${NC}"
            else
                echo -e "${RED}Failed to remove cron entry${NC}"
                exit 1
            fi
            exit 0
        fi

        # Handle --scheduled option (internal, used by cron)
        if [[ "$DO_SCHEDULED" == "true" ]]; then
            # Log to file for cron debugging
            echo "$(date): Starting scheduled backup" >> /tmp/infinibay-backup-scheduled.log

            # Check if containers are running
            if ! check_containers_running; then
                echo "$(date): Error - containers not running, skipping backup" >> /tmp/infinibay-backup-scheduled.log
                exit 1
            fi

            # Create scheduled backup
            set +e
            create_backup "scheduled"
            backup_exit_code=$?
            set -e

            if [[ $backup_exit_code -eq 0 ]]; then
                echo "$(date): Scheduled backup completed successfully" >> /tmp/infinibay-backup-scheduled.log
            else
                echo "$(date): Scheduled backup failed with exit code $backup_exit_code" >> /tmp/infinibay-backup-scheduled.log
            fi

            exit $backup_exit_code
        fi

        # Default: Create manual backup
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║         Infinibay Manual Backup                              ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # Build backup label
        backup_label="manual"
        if [[ -n "$BACKUP_LABEL" ]]; then
            # Sanitize label: replace spaces with underscores, remove special chars
            sanitized_label=$(echo "$BACKUP_LABEL" | tr ' ' '_' | tr -cd '[:alnum:]_-')
            backup_label="manual_${sanitized_label}"
        fi

        echo -e "${BLUE}Creating backup with label: ${GREEN}$backup_label${NC}"
        echo ""

        set +e
        create_backup "$backup_label"
        backup_exit_code=$?
        set -e

        if [[ $backup_exit_code -eq 0 ]]; then
            echo ""
            echo -e "${GREEN}Backup completed successfully!${NC}"
            echo -e "${YELLOW}To list all backups: ${BLUE}$0 backup --list${NC}"
            echo -e "${YELLOW}To restore: ${BLUE}$0 rollback <backup_path>${NC}"
        else
            echo -e "${RED}Backup failed${NC}"
        fi

        exit $backup_exit_code
        ;;

    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo -e "Run ${BLUE}$0 help${NC} for usage information"
        exit 1
        ;;
esac

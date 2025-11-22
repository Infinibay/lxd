#!/bin/bash
set -euo pipefail

# Infinibay LXD Setup Script
# Prepares the host system for running Infinibay with LXD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Source the universal package manager library
source "${SCRIPT_DIR}/lib/package-manager.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_kvm_support() {
    log_info "Checking KVM support..."

    if [[ ! -c /dev/kvm ]]; then
        log_error "/dev/kvm not found. KVM virtualization not available."
        log_info "Enable virtualization in your BIOS/UEFI settings."
        exit 1
    fi

    if ! kvm-ok &>/dev/null; then
        log_warning "kvm-ok command not found. Installing cpu-checker..."
        pkg_update
        pkg_install cpu-checker
    fi

    if kvm-ok &>/dev/null; then
        log_success "KVM acceleration available"
    else
        log_error "KVM acceleration not available on this system"
        exit 1
    fi
}

install_lxd() {
    log_info "Checking LXD installation..."

    if command -v lxc &>/dev/null; then
        log_success "LXD already installed: $(lxc version)"
    else
        log_info "Installing LXD via snap..."
        snap install lxd
        log_success "LXD installed successfully"
    fi

    # Ensure current user is in lxd group
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! groups "$SUDO_USER" | grep -q "\blxd\b"; then
            log_info "Adding $SUDO_USER to lxd group..."
            usermod -aG lxd "$SUDO_USER"
            log_warning "User added to lxd group. You MUST run 'newgrp lxd' or logout/login for changes to take effect!"
        else
            log_success "User $SUDO_USER already in lxd group"
        fi
    fi
}

install_lxd_compose() {
    log_info "Checking lxd-compose installation..."

    if command -v lxd-compose &>/dev/null; then
        log_success "lxd-compose already installed"
        return 0
    fi

    log_info "Installing lxd-compose..."

    # Install Go if not present (required for lxd-compose)
    if ! command -v go &>/dev/null; then
        log_info "Installing Go..."
        snap install go --classic
    fi

    # Note: Cannot use 'go install' due to replace directives in go.mod
    # Solution: Clone and build manually
    log_info "Cloning lxd-compose repository..."

    TEMP_DIR=$(mktemp -d)
    ORIG_DIR=$(pwd)
    cd "$TEMP_DIR"

    if ! git clone https://github.com/MottainaiCI/lxd-compose.git 2>&1; then
        log_error "Failed to clone lxd-compose repository"
        cd "$ORIG_DIR"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    cd lxd-compose

    log_info "Building lxd-compose..."
    if ! go build -o lxd-compose . 2>&1; then
        log_error "Failed to build lxd-compose"
        cd "$ORIG_DIR"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Install binary
    mv lxd-compose /usr/local/bin/lxd-compose
    chmod +x /usr/local/bin/lxd-compose

    # Cleanup
    cd "$ORIG_DIR"
    rm -rf "$TEMP_DIR"

    log_success "lxd-compose installed successfully"
}

initialize_lxd() {
    log_info "Initializing LXD..."

    # Check if already initialized
    if lxd waitready &>/dev/null; then
        log_success "LXD already initialized"
        return 0
    fi

    # Initialize with preseed for automation
    cat <<EOF | lxd init --preseed
config:
  core.https_address: '[::]:8443'
  core.trust_password: infinibay
networks:
- config:
    ipv4.address: auto
    ipv6.address: none
  description: "Default LXD bridge"
  name: lxdbr0
  type: bridge
storage_pools:
- config:
    size: 50GB
  description: "Default storage pool"
  name: default
  driver: dir
profiles:
- config: {}
  description: "Default LXD profile"
  devices:
    eth0:
      name: eth0
      nictype: bridged
      parent: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
EOF

    log_success "LXD initialized"
}

create_data_directories() {
    log_info "Creating data directories..."

    mkdir -p /var/lib/infinibay/data/{isos,disks,wallpapers,sockets}
    mkdir -p /var/lib/infinibay/postgres-data
    mkdir -p /var/lib/infinibay/redis-data

    chmod 755 /var/lib/infinibay
    chmod 755 /var/lib/infinibay/data

    log_success "Data directories created"
}

configure_lxc_for_user() {
    log_info "Configuring LXC for user..."

    if [[ -z "${SUDO_USER:-}" ]]; then
        log_warning "Cannot determine user. Skipping LXC configuration."
        return 0
    fi

    local USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    local LXC_CONFIG_DIR="$USER_HOME/.config/lxc"
    local LXC_CONFIG_FILE="$LXC_CONFIG_DIR/config.yml"

    # Create config directory
    if [[ ! -d "$LXC_CONFIG_DIR" ]]; then
        mkdir -p "$LXC_CONFIG_DIR"
        chown "$SUDO_USER:$SUDO_USER" "$LXC_CONFIG_DIR"
        chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.config"
    fi

    # Create config file if it doesn't exist
    if [[ ! -f "$LXC_CONFIG_FILE" ]]; then
        cat > "$LXC_CONFIG_FILE" << 'EOF'
default-remote: local
remotes:
  images:
    addr: https://images.lxd.canonical.com
    protocol: simplestreams
    public: true
  local:
    addr: unix://
    protocol: lxd
    public: false
  ubuntu:
    addr: https://cloud-images.ubuntu.com/releases/
    protocol: simplestreams
    public: true
  ubuntu-daily:
    addr: https://cloud-images.ubuntu.com/daily/
    protocol: simplestreams
    public: true
  ubuntu-minimal:
    addr: https://cloud-images.ubuntu.com/minimal/releases/
    protocol: simplestreams
    public: true
  ubuntu-minimal-daily:
    addr: https://cloud-images.ubuntu.com/minimal/daily/
    protocol: simplestreams
    public: true
aliases: {}
EOF
        chown "$SUDO_USER:$SUDO_USER" "$LXC_CONFIG_FILE"
        log_success "Created LXC config file: $LXC_CONFIG_FILE"
    else
        log_success "LXC config file already exists"
    fi
}

check_env_file() {
    log_info "Checking environment configuration..."

    if [[ ! -f "$ENV_FILE" ]]; then
        log_warning ".env file not found"
        log_info "Copying .env.example to .env..."
        cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
        log_warning "Please edit $ENV_FILE with your configuration before deploying"

        # Auto-detect host IP
        HOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo "")
        if [[ -n "$HOST_IP" ]]; then
            sed -i "s/HOST_IP=.*/HOST_IP=$HOST_IP/" "$ENV_FILE"
            log_info "Auto-detected host IP: $HOST_IP"
        fi

        # Generate random passwords
        DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)

        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" "$ENV_FILE"
        sed -i "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$ADMIN_PASSWORD/" "$ENV_FILE"

        log_success "Generated secure passwords in .env file"
        log_warning "IMPORTANT: Review and customize $ENV_FILE before deployment!"

        return 1
    fi

    log_success "Environment file found: $ENV_FILE"
    return 0
}

install_dependencies() {
    log_info "Installing system dependencies..."

    pkg_update

    # Install required packages
    PACKAGES=(
        libvirt-daemon-system
        libvirt-clients
        qemu-kvm
        cpu-checker
        bridge-utils
        curl
        git
        openssl
    )

    for package in "${PACKAGES[@]}"; do
        if ! pkg_is_installed "$package"; then
            log_info "Installing $package..."
            pkg_install "$package"
        fi
    done

    # Ensure libvirt is running
    local LIBVIRT_SERVICE=$(get_service_name libvirt)
    systemctl enable "$LIBVIRT_SERVICE"
    systemctl start "$LIBVIRT_SERVICE"

    log_success "System dependencies installed"
}

show_next_steps() {
    echo ""
    echo "=============================================="
    log_success "Setup completed successfully!"
    echo "=============================================="
    echo ""

    # Check if user needs to activate lxd group
    local NEEDS_NEWGRP=false
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! sudo -u "$SUDO_USER" groups | grep -q "\blxd\b"; then
            NEEDS_NEWGRP=true
        fi
    fi

    if [[ "$NEEDS_NEWGRP" == "true" ]]; then
        echo -e "${YELLOW}⚠️  IMPORTANT: User was added to lxd group${NC}"
        echo ""
        echo "Before running lxd-compose, you MUST activate the group change:"
        echo ""
        echo "  Option 1 (Quick - in current session):"
        echo -e "    ${BLUE}newgrp lxd${NC}"
        echo ""
        echo "  Option 2 (Permanent - requires re-login):"
        echo -e "    ${BLUE}logout and login again${NC}"
        echo ""
        echo "Then continue with the steps below:"
        echo ""
    fi

    echo "Next steps:"
    echo ""
    echo "1. Review and customize your configuration:"
    echo -e "   ${BLUE}nano $ENV_FILE${NC}"
    echo ""
    echo "2. Deploy Infinibay containers:"
    echo -e "   ${BLUE}cd $SCRIPT_DIR${NC}"
    echo -e "   ${BLUE}lxd-compose apply infinibay${NC}"
    echo ""
    echo "3. Check container status:"
    echo -e "   ${BLUE}lxc list${NC}"
    echo ""
    echo "4. Access Infinibay:"
    echo -e "   Frontend:  ${GREEN}http://$(grep HOST_IP= "$ENV_FILE" | cut -d= -f2):3000${NC}"
    echo -e "   GraphQL:   ${GREEN}http://$(grep HOST_IP= "$ENV_FILE" | cut -d= -f2):4000/graphql${NC}"
    echo ""
    echo "5. View logs:"
    echo -e "   ${BLUE}lxc exec infinibay-backend -- journalctl -f${NC}"
    echo ""
    echo -e "For troubleshooting, see: ${BLUE}$SCRIPT_DIR/INSTALL.md${NC}"
    echo ""
}

main() {
    echo ""
    echo "=============================================="
    echo "  Infinibay LXD Setup"
    echo "=============================================="
    echo ""

    check_root
    check_kvm_support
    install_dependencies
    install_lxd
    initialize_lxd
    install_lxd_compose
    create_data_directories
    configure_lxc_for_user

    if ! check_env_file; then
        log_warning "Setup paused. Please configure .env file and run this script again."
        exit 0
    fi

    show_next_steps
}

main "$@"

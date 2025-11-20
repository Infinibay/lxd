#!/bin/bash
set -euo pipefail

# Infinibay LXD Setup Script
# Prepares the host system for running Infinibay with LXD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

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
        apt-get update -qq
        apt-get install -y cpu-checker
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
        return 0
    fi

    log_info "Installing LXD via snap..."
    snap install lxd

    # Add current user to lxd group (if not root)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG lxd "$SUDO_USER"
        log_info "Added $SUDO_USER to lxd group. You may need to log out and back in."
    fi

    log_success "LXD installed successfully"
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

    # Install lxd-compose from source
    export GOPATH=/opt/go
    mkdir -p "$GOPATH"
    go install github.com/MottainaiCI/lxd-compose@latest

    # Create symlink to make it accessible
    ln -sf "$GOPATH/bin/lxd-compose" /usr/local/bin/lxd-compose

    log_success "lxd-compose installed"
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

    apt-get update -qq

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
        if ! dpkg -l | grep -q "^ii  $package"; then
            log_info "Installing $package..."
            apt-get install -y "$package"
        fi
    done

    # Ensure libvirt is running
    systemctl enable libvirtd
    systemctl start libvirtd

    log_success "System dependencies installed"
}

show_next_steps() {
    echo ""
    echo "=============================================="
    log_success "Setup completed successfully!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Review and customize your configuration:"
    echo "   ${BLUE}nano $ENV_FILE${NC}"
    echo ""
    echo "2. Deploy Infinibay containers:"
    echo "   ${BLUE}cd $SCRIPT_DIR${NC}"
    echo "   ${BLUE}lxd-compose up${NC}"
    echo ""
    echo "3. Check container status:"
    echo "   ${BLUE}lxc list${NC}"
    echo ""
    echo "4. Access Infinibay:"
    echo "   Frontend:  ${GREEN}http://$(grep HOST_IP= "$ENV_FILE" | cut -d= -f2):3000${NC}"
    echo "   GraphQL:   ${GREEN}http://$(grep HOST_IP= "$ENV_FILE" | cut -d= -f2):4000/graphql${NC}"
    echo ""
    echo "5. View logs:"
    echo "   ${BLUE}lxc exec infinibay-backend -- journalctl -u infinibay-backend -f${NC}"
    echo ""
    echo "For troubleshooting, see: ${BLUE}$SCRIPT_DIR/README.md${NC}"
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

    if ! check_env_file; then
        log_warning "Setup paused. Please configure .env file and run this script again."
        exit 0
    fi

    show_next_steps
}

main "$@"

#!/bin/bash
#
# Universal Package Manager Detection Library
# Provides cross-distribution package management functions
#

# Global variables
PKG_MANAGER=""
OS_FAMILY=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CHECK_CMD=""

# Detect OS family from /etc/os-release
detect_os_family() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu|linuxmint)
                OS_FAMILY="debian"
                ;;
            rhel|centos|fedora|rocky|almalinux)
                OS_FAMILY="rhel"
                ;;
            opensuse|opensuse-leap|opensuse-tumbleweed|sles)
                OS_FAMILY="suse"
                ;;
            arch|manjaro|endeavouros)
                OS_FAMILY="arch"
                ;;
            *)
                echo "Warning: Unknown OS family: $ID" >&2
                return 1
                ;;
        esac
        return 0
    else
        echo "Error: /etc/os-release not found" >&2
        return 1
    fi
}

# Detect package manager and set global variables
detect_package_manager() {
    detect_os_family || return 1

    case "$OS_FAMILY" in
        debian)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt"
                PKG_UPDATE_CMD="apt-get update -qq"
                PKG_INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y"
                PKG_CHECK_CMD="dpkg -l"
            else
                echo "Error: apt-get not found on Debian-based system" >&2
                return 1
            fi
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
                PKG_UPDATE_CMD="dnf check-update -q || true"
                PKG_INSTALL_CMD="dnf install -y -q"
                PKG_CHECK_CMD="rpm -q"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
                PKG_UPDATE_CMD="yum check-update -q || true"
                PKG_INSTALL_CMD="yum install -y -q"
                PKG_CHECK_CMD="rpm -q"
            else
                echo "Error: Neither dnf nor yum found on RHEL-based system" >&2
                return 1
            fi
            ;;
        suse)
            if command -v zypper >/dev/null 2>&1; then
                PKG_MANAGER="zypper"
                PKG_UPDATE_CMD="zypper refresh -q"
                PKG_INSTALL_CMD="zypper install -y -n"
                PKG_CHECK_CMD="rpm -q"
            else
                echo "Error: zypper not found on SUSE-based system" >&2
                return 1
            fi
            ;;
        arch)
            if command -v pacman >/dev/null 2>&1; then
                PKG_MANAGER="pacman"
                PKG_UPDATE_CMD="pacman -Sy --noconfirm"
                PKG_INSTALL_CMD="pacman -S --noconfirm --needed"
                PKG_CHECK_CMD="pacman -Q"
            else
                echo "Error: pacman not found on Arch-based system" >&2
                return 1
            fi
            ;;
        *)
            echo "Error: Unsupported OS family: $OS_FAMILY" >&2
            return 1
            ;;
    esac

    echo "Detected package manager: $PKG_MANAGER (OS family: $OS_FAMILY)"
    return 0
}

# Map generic package names to distribution-specific names
map_package_name() {
    local package="$1"

    case "$package" in
        build-essential)
            case "$OS_FAMILY" in
                debian) echo "build-essential" ;;
                rhel) echo "@development-tools" ;;
                arch) echo "base-devel" ;;
                suse) echo "patterns-devel-base-devel_basis" ;;
                *) echo "$package" ;;
            esac
            ;;
        cpu-checker)
            case "$OS_FAMILY" in
                debian) echo "cpu-checker" ;;
                *) echo "" ;; # Not available/needed on other distributions
            esac
            ;;
        libvirt-daemon-system)
            case "$OS_FAMILY" in
                debian) echo "libvirt-daemon-system" ;;
                rhel) echo "libvirt-daemon" ;;
                arch) echo "libvirt" ;;
                suse) echo "libvirt-daemon" ;;
                *) echo "$package" ;;
            esac
            ;;
        libvirt-dev)
            case "$OS_FAMILY" in
                debian) echo "libvirt-dev" ;;
                rhel|suse) echo "libvirt-devel" ;;
                arch) echo "libvirt" ;;
                *) echo "$package" ;;
            esac
            ;;
        qemu-kvm)
            case "$OS_FAMILY" in
                debian|rhel|suse) echo "qemu-kvm" ;;
                arch) echo "qemu-base" ;;
                *) echo "$package" ;;
            esac
            ;;
        postgresql)
            case "$OS_FAMILY" in
                debian|arch|suse) echo "postgresql" ;;
                rhel) echo "postgresql-server" ;;
                *) echo "$package" ;;
            esac
            ;;
        postgresql-contrib)
            case "$OS_FAMILY" in
                debian|rhel|suse) echo "postgresql-contrib" ;;
                arch) echo "" ;; # Included in postgresql package on Arch
                *) echo "$package" ;;
            esac
            ;;
        redis-server|redis)
            case "$OS_FAMILY" in
                debian) echo "redis-server" ;;
                rhel|arch|suse) echo "redis" ;;
                *) echo "$package" ;;
            esac
            ;;
        python3-pip)
            case "$OS_FAMILY" in
                debian|rhel|arch|suse) echo "python3-pip" ;;
                *) echo "$package" ;;
            esac
            ;;
        *)
            # No mapping needed, return as-is
            echo "$package"
            ;;
    esac
}

# Get the correct service name for a service
get_service_name() {
    local service="$1"

    case "$service" in
        libvirt|libvirtd)
            case "$OS_FAMILY" in
                debian|rhel|suse) echo "libvirtd" ;;
                arch) echo "libvirtd" ;;
                *) echo "libvirtd" ;;
            esac
            ;;
        redis)
            case "$OS_FAMILY" in
                debian) echo "redis-server" ;;
                rhel|arch|suse) echo "redis" ;;
                *) echo "redis" ;;
            esac
            ;;
        postgresql)
            # Note: On RHEL, version might be appended (e.g., postgresql-15)
            echo "postgresql"
            ;;
        *)
            echo "$service"
            ;;
    esac
}

# Get the correct config file path for a service
get_config_path() {
    local service="$1"

    case "$service" in
        redis)
            case "$OS_FAMILY" in
                debian) echo "/etc/redis/redis.conf" ;;
                rhel|arch) echo "/etc/redis/redis.conf" ;;
                suse) echo "/etc/redis/default.conf" ;;
                *) echo "/etc/redis/redis.conf" ;;
            esac
            ;;
        *)
            echo ""
            ;;
    esac
}

# Update package manager cache
pkg_update() {
    echo "Updating package manager cache..."
    eval $PKG_UPDATE_CMD
}

# Install one or more packages
pkg_install() {
    local packages=()
    local mapped_package

    for package in "$@"; do
        mapped_package=$(map_package_name "$package")
        if [ -n "$mapped_package" ]; then
            packages+=("$mapped_package")
        fi
    done

    if [ ${#packages[@]} -eq 0 ]; then
        echo "No packages to install (all mapped to empty)"
        return 0
    fi

    echo "Installing packages: ${packages[*]}"

    # Special handling for group packages on RHEL
    if [ "$OS_FAMILY" = "rhel" ]; then
        for pkg in "${packages[@]}"; do
            if [[ "$pkg" == @* ]]; then
                # Group install
                $PKG_MANAGER group install -y -q "$pkg"
            else
                # Regular install
                eval $PKG_INSTALL_CMD "$pkg"
            fi
        done
    else
        eval $PKG_INSTALL_CMD "${packages[@]}"
    fi
}

# Check if a package is installed
pkg_is_installed() {
    local package="$1"
    local mapped_package=$(map_package_name "$package")

    if [ -z "$mapped_package" ]; then
        # Package maps to empty (not available on this distro)
        return 1
    fi

    case "$PKG_MANAGER" in
        apt)
            dpkg -l "$mapped_package" 2>/dev/null | grep -q "^ii"
            ;;
        dnf|yum|zypper)
            rpm -q "$mapped_package" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Q "$mapped_package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# Special function to install Node.js 20.x
install_nodejs() {
    echo "Installing Node.js 20.x..."

    case "$OS_FAMILY" in
        debian|rhel)
            # Use NodeSource script for Debian and RHEL families
            if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 20 ]; then
                echo "Installing Node.js 20.x from NodeSource..."
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | grep -v "^#"
                pkg_install nodejs
            else
                echo "Node.js 20+ already installed: $(node -v)"
            fi
            ;;
        arch)
            # Use native repos on Arch
            pkg_install nodejs npm
            ;;
        suse)
            # Use native repos on openSUSE
            pkg_install nodejs20 npm20
            ;;
        *)
            echo "Error: Node.js installation not supported for $OS_FAMILY" >&2
            return 1
            ;;
    esac
}

# Initialize PostgreSQL database (distribution-specific)
init_postgresql() {
    case "$OS_FAMILY" in
        rhel)
            # RHEL requires explicit initialization
            if [ ! -d "/var/lib/pgsql/data/base" ]; then
                echo "Initializing PostgreSQL database..."
                if command -v postgresql-setup >/dev/null 2>&1; then
                    postgresql-setup --initdb || postgresql-setup initdb
                else
                    # Fallback for newer versions
                    /usr/bin/postgresql-setup --initdb
                fi
            fi
            ;;
        debian|arch|suse)
            # These distributions handle initialization automatically
            echo "PostgreSQL initialization handled automatically on $OS_FAMILY"
            ;;
    esac
}

# Auto-detect package manager on source
detect_package_manager

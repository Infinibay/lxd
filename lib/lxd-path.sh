#!/bin/bash
#
# LXD Installation Path Detection Library
# Provides automatic detection of LXD installation type (snap vs native)
#

# Global variable
LXD_DIR=""

# Detect LXD installation path by checking for socket files
detect_lxd_path() {
    # Respect pre-set LXD_DIR if already defined
    if [ -n "$LXD_DIR" ]; then
        # Optionally verify the socket exists at the pre-set path
        if [ -S "$LXD_DIR/unix.socket" ]; then
            [ -n "$LXD_DEBUG" ] && echo "Using pre-set LXD_DIR: $LXD_DIR"
            export LXD_DIR
            return 0
        else
            echo "Warning: Pre-set LXD_DIR ($LXD_DIR) does not contain a valid LXD socket. Attempting auto-detection..." >&2
        fi
    fi

    # Check for snap installation first
    if [ -S "/var/snap/lxd/common/lxd/unix.socket" ]; then
        LXD_DIR="/var/snap/lxd/common/lxd"
        [ -n "$LXD_DEBUG" ] && echo "Detected LXD installation: snap"
        export LXD_DIR
        return 0
    fi

    # Check for native package installation
    if [ -S "/var/lib/lxd/unix.socket" ]; then
        LXD_DIR="/var/lib/lxd"
        [ -n "$LXD_DEBUG" ] && echo "Detected LXD installation: native package"
        export LXD_DIR
        return 0
    fi

    # Neither installation found
    echo "Error: LXD installation not found. Checked snap (/var/snap/lxd/common/lxd) and native (/var/lib/lxd) paths." >&2
    return 1
}

# Auto-detect LXD path on source
detect_lxd_path

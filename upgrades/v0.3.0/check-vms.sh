#!/usr/bin/env bash

# check-vms.sh - Check for running VMs before upgrade
#
# This script checks if any VMs are currently running and warns the user.
# This is a non-critical check (required: false in manifest).

set -e

echo "Checking for running VMs..."

# Check if virsh is available in backend container
if ! lxc exec infinibay-backend -- which virsh > /dev/null 2>&1; then
    echo "Warning: virsh not found, skipping VM check"
    exit 0
fi

# Get list of running VMs
RUNNING_VMS=$(lxc exec infinibay-backend -- virsh list --state-running --name 2>/dev/null | grep -v '^$' || true)

if [ -n "$RUNNING_VMS" ]; then
    VM_COUNT=$(echo "$RUNNING_VMS" | wc -l)
    echo ""
    echo "  WARNING: $VM_COUNT VM(s) are currently running:"
    echo "$RUNNING_VMS" | sed 's/^/  - /'
    echo ""
    echo "These VMs will continue running during the upgrade, but may experience:"
    echo "  - Brief network connectivity loss during backend restart"
    echo "  - Temporary inability to manage VMs via UI during frontend restart"
    echo ""
    echo "Recommendation: Stop non-critical VMs before upgrading."
    echo ""
else
    echo "  No running VMs detected"
fi

exit 0

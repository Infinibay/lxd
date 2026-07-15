"""Host kernel-module probing for the VM networking/hypervisor path.

Faithful port of dev.sh `module_loaded` / `ensure_host_modules` detection: a module
counts as available if it is a loaded LKM (/sys/module), listed in /proc/modules, OR
COMPILED-IN (modules.builtin — e.g. tun with CONFIG_TUN=y). All three are plain
reads, so the caller can decide whether `sudo modprobe` is even needed before
touching sudo — the guard that stops a redundant password prompt on every `up`.
"""

from __future__ import annotations

import platform
from pathlib import Path


def module_loaded(name: str) -> bool:
    if Path(f"/sys/module/{name}").is_dir():
        return True
    try:
        with open("/proc/modules") as fh:
            if any(line.startswith(f"{name} ") for line in fh):
                return True
    except OSError:
        pass
    builtin = Path(f"/lib/modules/{platform.uname().release}/modules.builtin")
    try:
        needle = f"/{name}.ko"
        return any(needle in line for line in builtin.read_text().splitlines())
    except OSError:
        return False


def kvm_module_name() -> str:
    """kvm_intel on Intel, kvm_amd elsewhere (matches dev.sh cpuinfo check)."""
    try:
        cpuinfo = Path("/proc/cpuinfo").read_text()
    except OSError:
        cpuinfo = ""
    return "kvm_intel" if "GenuineIntel" in cpuinfo else "kvm_amd"


def required_vm_modules() -> list[str]:
    """br_netfilter (bridge→iptables/DHCP), tun (TAP), vhost_net + kvm (hypervisor)."""
    return ["br_netfilter", "tun", "vhost_net", "kvm", kvm_module_name()]


def missing_modules() -> list[str]:
    return [m for m in required_vm_modules() if not module_loaded(m)]

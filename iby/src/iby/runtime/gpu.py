"""GPU detection for the infinigpu render path — NVIDIA-only for now.

Side-effect-free (mirrors runtime/detect.py): probes the host for a supported GPU
and for the artifacts the GPU compose override depends on, so `iby up --gpu`,
`iby gpu status`, and `iby doctor` share one source of truth. Actions that write
(generating the CDI spec) live in services/gpu.py.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from ..core.process import Runner
from ..models.enums import GpuVendor

# NVIDIA Container Toolkit writes the CDI spec here; the (podman) runtime reads
# /etc/cdi to resolve `nvidia.com/gpu=…` device names.
CDI_SPEC = Path("/etc/cdi/nvidia.yaml")
# Where scripts/build-qemu-vfio-user.sh installs the QEMU with the vfio-user-pci
# client that infinigpu GPU VMs require.
VFIO_USER_QEMU = Path("/opt/qemu-vfio-user/bin/qemu-system-x86_64")


def detect_vendor() -> GpuVendor:
    """The host GPU vendor, or `none`. NVIDIA if its driver node or CLI is present."""
    if Path("/dev/nvidia0").exists() or shutil.which("nvidia-smi") is not None:
        return GpuVendor.nvidia
    return GpuVendor.none


def nvidia_gpus(runner: Runner) -> list[str]:
    """One `index, name, memory` line per NVIDIA GPU (empty if nvidia-smi absent)."""
    if shutil.which("nvidia-smi") is None:
        return []
    out = runner.capture(["nvidia-smi", "--query-gpu=index,name,memory.total", "--format=csv,noheader"])
    return [line.strip() for line in out.splitlines() if line.strip()]


def has_nvidia_ctk() -> bool:
    """The NVIDIA Container Toolkit CLI (`nvidia-ctk`) — needed to generate the CDI spec."""
    return shutil.which("nvidia-ctk") is not None


def cdi_ready() -> bool:
    """True when the NVIDIA CDI spec exists and is an nvidia.com/gpu manifest.

    The generated YAML declares `kind: nvidia.com/gpu` with devices `name: all`,
    `name: "0"`, … — so we match the kind, not a literal `nvidia.com/gpu=all`
    (that qualified form only appears in `nvidia-ctk cdi list`, not the spec file).
    """
    try:
        return CDI_SPEC.exists() and "nvidia.com/gpu" in CDI_SPEC.read_text()
    except OSError:
        return False


def vfio_user_qemu() -> Path | None:
    """The vfio-user QEMU binary, if built (scripts/build-qemu-vfio-user.sh)."""
    return VFIO_USER_QEMU if VFIO_USER_QEMU.exists() else None


def device_binary(repos_dir: Path) -> Path | None:
    """The release-built `infinigpu-device` server binary, if present."""
    p = repos_dir / "infinigpu" / "target" / "release" / "infinigpu-device"
    return p if p.exists() else None


def override_path(repos_dir: Path) -> Path:
    """The GPU compose override shipped in the infinigpu repo."""
    return repos_dir / "infinigpu" / "deploy" / "docker-compose.gpu.yml"

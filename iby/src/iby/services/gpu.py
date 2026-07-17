"""infinigpu GPU enablement for the dev stack (NVIDIA-only for now).

Detects the host GPU, ensures the prerequisites the GPU compose override needs —
chiefly the NVIDIA **CDI spec** so the container can see the GPU and its userspace
libraries (libnvidia-encode for NVENC, the Vulkan ICD) — and returns the override
path for the stack to compose in.

IMPORTANT — infinigpu is **API-remoting, not VFIO passthrough**: the host KEEPS
the NVIDIA driver bound and renders on the GPU itself (Vulkan + NVENC); the guest
gets a userspace-emulated *vfio-user* device. So there is deliberately **no driver
blacklist / vfio-pci bind** here — that belongs to the separate dedicated-passthrough
feature (one whole GPU to one VM), which is a different mode.

Privileged operations follow one rule: **EXPLAIN (what / why / which files) →
CONFIRM → sudo → execute.** Nothing touches the host silently.
"""

from __future__ import annotations

import os
from pathlib import Path

from rich.table import Table

from ..core.context import AppContext
from ..core.errors import IbyError
from ..models.enums import GpuVendor
from ..runtime import gpu as gpu_rt


def ensure_gpu_ready(ctx: AppContext, repos_dir: Path) -> Path:
    """Detect the GPU, ensure prerequisites (transparently), and return the compose
    override path to append. Raises IbyError with actionable guidance on a hard gap."""
    vendor = gpu_rt.detect_vendor()
    if vendor is GpuVendor.none:
        raise IbyError(
            "no supported GPU detected — --gpu needs an NVIDIA GPU for now.",
            hint="check `nvidia-smi`; AMD/Intel are not wired yet.",
        )
    ctx.console.info(f"GPU vendor detected: {vendor.value}")
    for line in gpu_rt.nvidia_gpus(ctx.runner):
        ctx.console.info(f"  • {line}")

    override = gpu_rt.override_path(repos_dir)
    if not override.exists():
        raise IbyError(
            f"infinigpu GPU compose override not found: {override}",
            hint="is repos/infinigpu checked out on this host? (`iby up` clones the app repos)",
        )

    _ensure_cdi(ctx)
    _preflight(ctx, repos_dir)
    return override


def _ensure_cdi(ctx: AppContext) -> None:
    """Ensure the NVIDIA CDI spec exists so the runtime can inject the GPU. Explains
    itself and asks for sudo before writing anything (owner's transparency rule)."""
    if gpu_rt.cdi_ready():
        ctx.console.info(f"NVIDIA CDI spec present ({gpu_rt.CDI_SPEC}) — the container can see the GPU.")
        return
    if not gpu_rt.has_nvidia_ctk():
        raise IbyError(
            "nvidia-ctk not found — cannot generate the NVIDIA CDI spec.",
            hint="install the NVIDIA Container Toolkit (nvidia-container-toolkit), then re-run.",
        )

    command = f"nvidia-ctk cdi generate --output={gpu_rt.CDI_SPEC}"
    if ctx.dry_run:
        ctx.console.info(f"[dry-run] would generate the NVIDIA CDI spec: sudo {command}")
        return
    ok = _explain_and_confirm(
        ctx,
        title="GPU setup — generate the NVIDIA CDI spec",
        why=(
            "The dev stack runs the backend (which renders on the GPU) inside a container. "
            "A CDI spec tells the container runtime how to inject the NVIDIA GPU device nodes "
            "AND the userspace libraries the render path needs (libnvidia-encode for NVENC, "
            "the Vulkan ICD). WITHOUT it the container cannot use the GPU.\n"
            "This does NOT change or blacklist your host driver — infinigpu renders on the host "
            "with the driver loaded (it is API-remoting, not passthrough)."
        ),
        files=[f"{gpu_rt.CDI_SPEC}  (created/overwritten — a generated device manifest)"],
        command=command,
    )
    if not ok:
        raise IbyError(
            "GPU setup declined — the NVIDIA CDI spec was not generated.",
            hint=f"approve it, or run it yourself: sudo {command}   (then re-run `iby up --gpu`)",
        )

    ctx.console.info("generating the NVIDIA CDI spec (sudo)…")
    sudo = os.geteuid() != 0
    res = ctx.runner.run(
        ["nvidia-ctk", "cdi", "generate", f"--output={gpu_rt.CDI_SPEC}"],
        sudo=sudo,
        check=False,
    )
    if not res.ok:
        raise IbyError(
            "nvidia-ctk cdi generate failed.",
            hint=f"run it manually to see the error: sudo {command}",
        )
    ctx.console.success(f"NVIDIA CDI spec generated → {gpu_rt.CDI_SPEC}")


def _preflight(ctx: AppContext, repos_dir: Path) -> None:
    """Non-fatal warnings for the two host artifacts the override bind-mounts."""
    if gpu_rt.vfio_user_qemu() is None:
        ctx.console.warn(
            f"vfio-user QEMU not found at {gpu_rt.VFIO_USER_QEMU} — GPU VMs will not boot. "
            "Build it: ( cd repos/infinigpu && ./scripts/build-qemu-vfio-user.sh )"
        )
    if gpu_rt.device_binary(repos_dir) is None:
        ctx.console.warn(
            "infinigpu-device binary not built — the per-VM device server cannot spawn. "
            "Build it: ( cd repos/infinigpu && cargo build --release -p infinigpu-device )"
        )


def _explain_and_confirm(ctx: AppContext, *, title: str, why: str, files: list[str], command: str) -> bool:
    """Print a structured what/why/which-files explanation, then ask to proceed.
    `--yes` short-circuits to yes. This is the standard shape for every privileged
    GPU operation (CDI now; a future dedicated-passthrough vfio-pci bind reuses it)."""
    lines = [
        f"[bold]Why:[/] {why}",
        "",
        "[bold]Files it will write:[/]",
        *[f"  • {f}" for f in files],
        "",
        "[bold]Command (run with sudo):[/]",
        f"  [cyan]sudo {command}[/]",
    ]
    ctx.console.banner(title, lines)
    return ctx.console.confirm("Proceed with this privileged step?", default=True)


def status(ctx: AppContext, repos_dir: Path) -> None:
    """Render the GPU readiness table (`iby gpu status`)."""
    vendor = gpu_rt.detect_vendor()
    table = Table(title="iby gpu", title_style="bold cyan", show_lines=False)
    table.add_column("item", style="bold")
    table.add_column("status")
    table.add_column("detail", overflow="fold")

    def row(name: str, ok: bool, detail: str, warn: bool = False) -> None:
        state = "ok" if ok else ("warn" if warn else "fail")
        style = {"ok": "green", "warn": "yellow", "fail": "red"}[state]
        table.add_row(name, f"[{style}]{state.upper()}[/]", detail)

    if vendor is GpuVendor.none:
        row("GPU vendor", False, "no supported GPU detected (NVIDIA only for now)", warn=True)
        ctx.console.render(table)
        return
    row("GPU vendor", True, vendor.value)
    gpus = gpu_rt.nvidia_gpus(ctx.runner)
    row("GPUs", bool(gpus), "; ".join(gpus) or "nvidia-smi returned none", warn=not gpus)
    row("nvidia-ctk", gpu_rt.has_nvidia_ctk(), "present" if gpu_rt.has_nvidia_ctk() else "missing (needed for CDI)", warn=True)
    row("CDI spec", gpu_rt.cdi_ready(), str(gpu_rt.CDI_SPEC) if gpu_rt.cdi_ready() else "absent — `iby gpu setup` generates it", warn=True)
    qemu = gpu_rt.vfio_user_qemu()
    row("vfio-user QEMU", qemu is not None, str(qemu) if qemu else "absent — ./scripts/build-qemu-vfio-user.sh", warn=True)
    binp = gpu_rt.device_binary(repos_dir)
    row("device binary", binp is not None, str(binp) if binp else "absent — cargo build --release -p infinigpu-device", warn=True)
    override = gpu_rt.override_path(repos_dir)
    row("compose override", override.exists(), str(override) if override.exists() else "absent — is repos/infinigpu checked out?", warn=True)
    ctx.console.render(table)

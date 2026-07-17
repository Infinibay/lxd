"""`iby doctor` — preflight the host before an `up`.

Read-only by default (safe to run anytime). `--fix` applies only the no-sudo
remedies (the user-level podman registries drop-in); anything needing root is
reported with the exact command to run, never silently sudo'd.
"""

from __future__ import annotations

import grp
import os
import platform
from dataclasses import dataclass
from pathlib import Path

from rich.table import Table

from ..core.context import AppContext
from ..core.errors import NoComposeProvider
from ..runtime import detect, gpu, modules, registries

_STATUS_STYLE = {"ok": "green", "warn": "yellow", "fail": "red", "n/a": "dim"}


@dataclass
class Check:
    name: str
    status: str  # ok | warn | fail | n/a
    detail: str


def _in_group(name: str) -> bool:
    try:
        gid = grp.getgrnam(name).gr_gid
    except KeyError:
        return False
    return gid in os.getgroups() or gid == os.getgid()


def run(ctx: AppContext, *, fix: bool = False) -> bool:
    """Run all checks, render a table, return False iff any check FAILED."""
    r = ctx.runner
    checks: list[Check] = []

    # ── project root ─────────────────────────────────────────────────────────
    if ctx.project_dir:
        checks.append(Check("project root", "ok", str(ctx.project_dir)))
    else:
        checks.append(Check("project root", "fail", "not found — cd into lxd or pass --project-dir"))

    # ── container CLI ────────────────────────────────────────────────────────
    has_docker, has_podman = detect.has("docker"), detect.has("podman")
    podman_backed = (has_docker or has_podman) and detect.is_podman(r)
    if has_docker or has_podman:
        which = "podman (docker shim)" if podman_backed else "docker"
        checks.append(Check("container CLI", "ok", which))
    else:
        checks.append(Check("container CLI", "fail", "neither docker nor podman on PATH"))

    # ── compose v2 provider ──────────────────────────────────────────────────
    try:
        provider = detect.resolve_compose(r)
        checks.append(Check("compose v2 provider", "ok", " ".join(provider)))
    except NoComposeProvider as exc:
        checks.append(Check("compose v2 provider", "fail", exc.hint or exc.message))

    # ── podman mode (informational: rootless ⇒ KVM needs sudo) ───────────────
    if podman_backed:
        rootless = detect.is_rootless_podman(r)
        checks.append(
            Check(
                "podman mode",
                "warn" if rootless else "ok",
                "rootless (KVM ⇒ sudo for host bridges/nft/TAP)" if rootless else "rootful",
            )
        )
        if registries.registries_configured():
            checks.append(Check("podman registries", "ok", "docker.io short-names resolved"))
        elif fix:
            registries.ensure_podman_registries(ctx)
            checks.append(Check("podman registries", "ok", "configured (--fix)"))
        else:
            checks.append(
                Check("podman registries", "warn", "bare image names unresolved — run: iby doctor --fix")
            )

    # ── /dev/kvm ─────────────────────────────────────────────────────────────
    if platform.system() != "Linux":
        checks.append(Check("/dev/kvm", "n/a", f"{platform.system()} — control-plane-only"))
    elif Path("/dev/kvm").exists():
        checks.append(Check("/dev/kvm", "ok", "present — VMs enabled"))
    else:
        checks.append(Check("/dev/kvm", "warn", "absent — control-plane-only (no VM create/start)"))

    # ── VM kernel modules + kvm group (only meaningful on a KVM host) ─────────
    if detect.kvm_available():
        missing = modules.missing_modules()
        if missing:
            checks.append(
                Check("VM kernel modules", "warn", "missing: " + " ".join(missing) + " (iby up loads them)")
            )
        else:
            checks.append(Check("VM kernel modules", "ok", "all present"))
        in_kvm = _in_group("kvm")
        checks.append(
            Check(
                "kvm group",
                "ok" if in_kvm else "warn",
                "member" if in_kvm else "not a member (rootless podman needs it for /dev/kvm)",
            )
        )

    # ── GPU (infinigpu render path — NVIDIA only for now) ────────────────────
    if platform.system() == "Linux":
        vendor = gpu.detect_vendor()
        if vendor.value == "nvidia":
            checks.append(Check("GPU", "ok", f"nvidia — {len(gpu.nvidia_gpus(r))} detected"))
            if gpu.cdi_ready():
                checks.append(Check("NVIDIA CDI", "ok", str(gpu.CDI_SPEC)))
            elif gpu.has_nvidia_ctk():
                checks.append(Check("NVIDIA CDI", "warn", "absent — `iby up --gpu` / `iby gpu setup` generates it (sudo)"))
            else:
                checks.append(Check("NVIDIA CDI", "warn", "nvidia-ctk missing — install nvidia-container-toolkit"))
            if gpu.vfio_user_qemu() is None:
                checks.append(Check("vfio-user QEMU", "warn", "absent — scripts/build-qemu-vfio-user.sh (needed for GPU VMs)"))
            else:
                checks.append(Check("vfio-user QEMU", "ok", str(gpu.VFIO_USER_QEMU)))
        else:
            checks.append(Check("GPU", "n/a", "no NVIDIA GPU detected — infinigpu render path off"))

    _render(ctx, checks)
    return not any(c.status == "fail" for c in checks)


def _render(ctx: AppContext, checks: list[Check]) -> None:
    table = Table(title="iby doctor", title_style="bold cyan", show_lines=False)
    table.add_column("check", style="bold")
    table.add_column("status")
    table.add_column("detail", overflow="fold")
    for c in checks:
        style = _STATUS_STYLE.get(c.status, "white")
        table.add_row(c.name, f"[{style}]{c.status.upper()}[/]", c.detail)
    ctx.console.render(table)

    fails = sum(c.status == "fail" for c in checks)
    warns = sum(c.status == "warn" for c in checks)
    if fails:
        ctx.console.error(f"{fails} check(s) FAILED — the stack will not come up cleanly.")
    elif warns:
        ctx.console.warn(f"{warns} warning(s) — usable, but review the notes above.")
    else:
        ctx.console.success("all checks passed.")

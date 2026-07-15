"""KVM decision + rootful-podman routing. Port of dev.sh detect_runtime.

Given the operator's --kvm/--no-kvm choice (or auto), decide control-plane-only vs
full hypervisor mode, and — only for rootless podman on Linux — route the engine
through sudo (rootful podman) so it can manage host bridges/nftables/TAP.
"""

from __future__ import annotations

import os
import platform
from dataclasses import dataclass

from ..core.context import AppContext
from ..core.errors import RuntimeUnavailable
from . import detect, registries


@dataclass
class RuntimeDecision:
    kvm_active: bool
    engine_sudo: bool
    extra_files: list[str]  # compose overlays to append (kvm)


def resolve_kvm(want_kvm: bool | None, merged_env: dict[str, str]) -> bool:
    """--kvm/--no-kvm wins; else KVM=on|off|auto env; else auto-detect /dev/kvm."""
    if want_kvm is True:
        return True
    if want_kvm is False:
        return False
    val = (merged_env.get("KVM") or "auto").lower()
    if val in ("on", "1", "true"):
        return True
    if val in ("off", "0", "false"):
        return False
    return detect.kvm_available()


def detect_runtime(ctx: AppContext, *, want_kvm: bool | None, merged_env: dict[str, str]) -> RuntimeDecision:
    if not resolve_kvm(want_kvm, merged_env):
        ctx.console.info("control-plane-only mode (no /dev/kvm, or KVM=off) — UI/API/DB, no VMs")
        return RuntimeDecision(kvm_active=False, engine_sudo=False, extra_files=[])

    ctx.console.info("full hypervisor mode — /dev/kvm present, VMs enabled")
    engine_sudo = False
    # Rootful only matters for podman; Docker's daemon is already root.
    if (
        platform.system() == "Linux"
        and detect.is_podman(ctx.runner)
        and os.geteuid() != 0
        and detect.is_rootless_podman(ctx.runner)
    ):
        if not detect.has("sudo"):
            raise RuntimeUnavailable(
                "rootless podman + KVM needs rootful access but 'sudo' is missing.",
                hint="install sudo, or run iby as root",
            )
        engine_sudo = True
        ctx.console.warn(
            "rootless podman can't manage host bridges/nft/TAP — routing the engine through "
            "sudo (rootful podman). You may be prompted for your password."
        )
        registries.ensure_root_registries(ctx)
    return RuntimeDecision(kvm_active=True, engine_sudo=engine_sudo, extra_files=["docker-compose.kvm.yml"])

"""Read-only detection of the container runtime + Compose v2 provider.

Ports dev.sh `resolve_compose` and the podman/rootless probes. Kept side-effect
free (no env writes, no modprobe) so `iby doctor` and the up path share one source
of truth for "what runtime am I on?".
"""

from __future__ import annotations

import platform
import re
import shutil
from pathlib import Path

from ..core.errors import MissingTool, NoComposeProvider
from ..core.process import Runner


def has(tool: str) -> bool:
    return shutil.which(tool) is not None


def container_cli() -> str:
    """The container CLI verb to invoke — **docker first, then podman** (autodetect).

    Every service that shells a raw engine command (volume ls, ps, restart, …) goes
    through this so iby works whether the host has real Docker, the podman-docker
    shim, or bare podman. Prefer docker when present (its socket may itself point at
    podman via DOCKER_HOST — that's the user's choice, and it still Just Works)."""
    if has("docker"):
        return "docker"
    if has("podman"):
        return "podman"
    raise MissingTool(
        "no container engine found (need docker or podman)",
        hint="install docker (with the compose plugin) or podman + podman-compose",
    )


def is_podman(runner: Runner) -> bool:
    """True when the resolved CLI is really podman (bare podman or the docker shim)."""
    if not has("docker"):
        return has("podman")
    return "podman" in runner.capture([container_cli(), "--version"]).lower()


def is_rootless_podman(runner: Runner) -> bool:
    if not is_podman(runner):
        return False
    return "rootless: true" in runner.capture([container_cli(), "info"])


def engine_is_podman(runner: Runner) -> bool:
    """True when the ACTIVE engine (server) is podman — including a real `docker` CLI
    whose DOCKER_HOST points at a podman socket.

    Checks the SERVER, not just the client, because `docker compose` driving a podman
    socket silently loses podman-native features the dev stack's KVM path depends on
    (notably `group_add: [keep-groups]`, which gives the rootless container /dev/kvm
    + GPU group access). `docker version` prints both halves; podman's server banner
    reads 'Podman Engine'. Falls back to the client-side shim probe if the server is
    unreachable."""
    if not has("docker"):
        return has("podman")
    if "podman" in runner.capture([container_cli(), "version"]).lower():
        return True
    return is_podman(runner)


def engine_supports_gpu_render(runner: Runner) -> bool:
    """True when the ACTIVE container engine can initialize NVIDIA **Vulkan** — the
    infinigpu 3D render path.

    NVIDIA's Vulkan driver does NOT initialize inside a rootless user namespace:
    `vk_icdNegotiateLoaderICDInterfaceVersion` returns INITIALIZATION_FAILED and the
    loader reports "no drivers", even though `nvidia-smi`, CUDA and NVENC all work
    fine there. So the render path needs a REAL (root) docker engine — the initial
    user namespace. Rootless podman (iby's Linux default) can drive the 2D/display
    path (NVENC) but every GPU vkQueueSubmit fails, so the guest triangle/desktop
    renders black.

    Checks the SERVER, not just the client: `engine_is_podman` already catches a real
    `docker` CLI whose DOCKER_HOST points at a podman socket. A rootless *docker* engine
    is rejected too (same userns limitation)."""
    if not has("docker"):
        return False
    if engine_is_podman(runner):
        return False
    return "rootless" not in runner.capture([container_cli(), "info"]).lower()


def kvm_available() -> bool:
    return platform.system() == "Linux" and Path("/dev/kvm").exists()


def _compose_major(text: str) -> int | None:
    """Major version from a `compose version` string, e.g. 'v5.0.2' → 5, '1.29.2' → 1."""
    m = re.search(r"v?(\d+)\.\d+", text)
    return int(m.group(1)) if m else None


def resolve_compose(runner: Runner) -> list[str]:
    """Pick a Compose Spec v2+ provider, matched to the ACTIVE engine (autodetect).

    The tool must match the engine, not just be "docker if present": a **podman**
    engine (even behind a `docker` CLI pointed at a podman socket) needs
    **podman-compose**, because `docker compose` over the podman socket drops
    podman-native features the KVM path relies on (`keep-groups` → rootless /dev/kvm).
    A **real docker** engine prefers **docker compose** → standalone `docker-compose`.
    Any compose major >= 2 is accepted (the plugin ships v2..v5); only legacy
    docker-compose v1 is rejected (the files use v2-only features).
    """
    # Podman engine → its native compose (docker compose can't do keep-groups here).
    if engine_is_podman(runner) and has("podman-compose"):
        return ["podman-compose"]
    # Real docker engine → the compose plugin, then the standalone v2+ binary.
    if has("docker"):
        major = _compose_major(runner.capture(["docker", "compose", "version"]))
        if major and major >= 2:
            return ["docker", "compose"]
    if has("docker-compose"):
        major = _compose_major(runner.capture(["docker-compose", "version", "--short"]))
        if major and major >= 2:
            return ["docker-compose"]
    # Last resort: podman-compose even if the engine probe was inconclusive.
    if has("podman-compose"):
        return ["podman-compose"]
    raise NoComposeProvider(
        "no Compose v2+ provider found. The compose files use v2-only features that "
        "legacy docker-compose v1 cannot parse.",
        hint="install the Docker Compose v2 plugin, or: sudo apt-get install -y podman-compose",
    )

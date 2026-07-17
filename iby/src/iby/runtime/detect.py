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


def kvm_available() -> bool:
    return platform.system() == "Linux" and Path("/dev/kvm").exists()


def _compose_major(text: str) -> int | None:
    """Major version from a `compose version` string, e.g. 'v5.0.2' → 5, '1.29.2' → 1."""
    m = re.search(r"v?(\d+)\.\d+", text)
    return int(m.group(1)) if m else None


def resolve_compose(runner: Runner) -> list[str]:
    """Pick a Compose Spec v2+ provider, **preferring docker, then podman** (autodetect).

    Order: `docker compose` plugin → standalone `docker-compose` (v2+) → `podman-compose`.
    Any major >= 2 is accepted (the plugin ships as v2/v3/…/v5); only legacy
    docker-compose v1 is rejected, since the files use v2-only features (top-level
    `name:`, x-* anchors).
    """
    if has("docker"):
        major = _compose_major(runner.capture(["docker", "compose", "version"]))
        if major and major >= 2:
            return ["docker", "compose"]
    if has("docker-compose"):
        major = _compose_major(runner.capture(["docker-compose", "version", "--short"]))
        if major and major >= 2:
            return ["docker-compose"]
    if has("podman-compose"):
        return ["podman-compose"]
    raise NoComposeProvider(
        "no Compose v2+ provider found. The compose files use v2-only features that "
        "legacy docker-compose v1 cannot parse.",
        hint="install the Docker Compose v2 plugin, or: sudo apt-get install -y podman-compose",
    )

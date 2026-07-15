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

from ..core.errors import NoComposeProvider
from ..core.process import Runner


def has(tool: str) -> bool:
    return shutil.which(tool) is not None


def is_podman(runner: Runner) -> bool:
    """True when `docker` is really podman (incl. the podman-docker CLI shim)."""
    return "podman" in runner.capture(["docker", "--version"]).lower()


def is_rootless_podman(runner: Runner) -> bool:
    if not is_podman(runner):
        return False
    return "rootless: true" in runner.capture(["docker", "info"])


def kvm_available() -> bool:
    return platform.system() == "Linux" and Path("/dev/kvm").exists()


def resolve_compose(runner: Runner) -> list[str]:
    """Pick a Compose Spec v2 provider, or raise with install guidance.

    Order (dev.sh): native podman-compose (spec-capable) → docker compose v2 →
    standalone docker-compose v2. Legacy docker-compose v1 is rejected because
    these files use v2-only features (top-level `name:`, x-* anchors).
    """
    if has("podman-compose"):
        return ["podman-compose"]
    if re.search(r"v?2\.", runner.capture(["docker", "compose", "version"])):
        return ["docker", "compose"]
    if has("docker-compose"):
        if re.match(r"^v?2\.", runner.capture(["docker-compose", "version", "--short"])):
            return ["docker-compose"]
    raise NoComposeProvider(
        "no Compose v2 provider found. The compose files use v2-only features that "
        "legacy docker-compose v1 cannot parse.",
        hint="sudo apt-get install -y podman-compose   (or install the Docker Compose v2 plugin)",
    )

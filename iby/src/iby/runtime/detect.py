"""Read-only detection of the container runtime + Compose v2 provider.

Ports dev.sh `resolve_compose` and the podman/rootless probes. Kept side-effect
free (no env writes, no modprobe) so `iby doctor` and the up path share one source
of truth for "what runtime am I on?".
"""

from __future__ import annotations

import os
import platform
import re
import shutil
from pathlib import Path

from ..core.errors import MissingTool, NoComposeProvider
from ..core.process import Runner

# Where the engines install themselves when `PATH` does not say so.
#
# `PATH` is a property of the SHELL, not of the machine, and the two disagree most on
# macOS: Docker Desktop 4.x installs its CLI into `~/.docker/bin` and appends that to
# PATH from the shell profile, so anything not launched from an interactive login shell
# — a GUI terminal with a trimmed profile, a launchd job, an editor's integrated
# terminal, `env -i` — sees a machine with "no docker on it". Homebrew has the same
# split by architecture: /opt/homebrew on Apple Silicon, /usr/local on Intel. Probing
# these directly is what makes "detect docker or podman" mean the same thing on macOS
# as on Linux instead of quietly meaning "detect the user's shell configuration".
_EXTRA_BIN_DIRS: dict[str, list[Path]] = {
    "Darwin": [
        Path.home() / ".docker" / "bin",
        Path("/usr/local/bin"),
        Path("/opt/homebrew/bin"),
        Path("/Applications/Docker.app/Contents/Resources/bin"),
        Path("/opt/podman/bin"),
    ],
    "Linux": [
        Path("/usr/local/bin"),
        Path("/usr/bin"),
        Path("/usr/local/lib/docker/cli-plugins"),
        Path("/snap/bin"),
    ],
}


def which(tool: str) -> str | None:
    """Absolute path to `tool`, searching `PATH` and then the platform's well-known
    install directories. `None` when it genuinely is not installed."""
    found = shutil.which(tool)
    if found:
        return found
    for d in _EXTRA_BIN_DIRS.get(platform.system(), []):
        cand = d / tool
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def has(tool: str) -> bool:
    return which(tool) is not None


def container_cli() -> str:
    """The container CLI to invoke — **docker first, then podman** (autodetect).

    Every service that shells a raw engine command (volume ls, ps, restart, …) goes
    through this so iby works whether the host has real Docker, the podman-docker
    shim, or bare podman. Prefer docker when present (its socket may itself point at
    podman via DOCKER_HOST — that's the user's choice, and it still Just Works).

    Returns an ABSOLUTE PATH, not a bare name: `which` deliberately looks beyond `PATH`,
    so a tool it found off-PATH has to be invoked by the path it was found at or the
    child process would fail to exec the very binary we just reported as present."""
    for tool in ("docker", "podman"):
        found = which(tool)
        if found:
            return found
    raise MissingTool(
        "no container engine found (need docker or podman)",
        hint=install_hint(),
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


def kvm_available() -> bool:
    return platform.system() == "Linux" and Path("/dev/kvm").exists()


def _compose_major(text: str) -> int | None:
    """Major version from a `compose version` string, e.g. 'v5.0.2' → 5, '1.29.2' → 1."""
    m = re.search(r"v?(\d+)\.\d+", text)
    return int(m.group(1)) if m else None


def install_hint() -> str:
    """How to get a provider ON THIS HOST. `apt-get` is not a universal instruction — a
    macOS user reading it learns nothing except that we did not consider them."""
    system = platform.system()
    if system == "Darwin":
        return (
            "install Docker Desktop (it ships Compose v2 as `docker compose`) and make sure "
            "`docker` is on PATH — Docker Desktop puts it in ~/.docker/bin, which only a login "
            "shell picks up. Or: brew install podman podman-compose"
        )
    if has("apt-get"):
        return "install the Docker Compose v2 plugin, or: sudo apt-get install -y podman-compose"
    return "install the Docker Compose v2 plugin (docker-compose-plugin), or podman + podman-compose"


def resolve_compose(runner: Runner) -> list[str]:
    """Pick a Compose Spec v2+ provider, matched to the ACTIVE engine (autodetect).

    The tool must match the engine, not just be "docker if present": a **podman**
    engine (even behind a `docker` CLI pointed at a podman socket) needs
    **podman-compose**, because `docker compose` over the podman socket drops
    podman-native features the KVM path relies on (`keep-groups` → rootless /dev/kvm).
    A **real docker** engine prefers **docker compose** → standalone `docker-compose`.
    Any compose major >= 2 is accepted (the plugin ships v2..v5); only legacy
    docker-compose v1 is rejected (the files use v2-only features).

    **Existence is proven by the exit code, not by parsing a version string.** The
    `docker compose` SUBCOMMAND is Compose v2 by construction — v1 only ever existed as
    the standalone `docker-compose` binary, and there is no v1 plugin to confuse it with.
    Gating on a parsed version meant that any build whose banner we could not parse — a
    locale that reorders the line, a vendor suffix, a version printed on stderr, which
    `Runner.capture` does not collect — was silently rejected and the user was told no
    provider existed while `docker compose` sat right there working. That is exactly the
    shape of the macOS report this function is being fixed for: Docker Desktop present,
    Compose v2 present, `iby doctor` insisting neither was. The version parse is kept only
    to REJECT a confidently-parsed v1, never to admit a v2.
    """
    tried: list[str] = []
    docker, dc_standalone, pc = which("docker"), which("docker-compose"), which("podman-compose")
    # Podman engine → its native compose (docker compose can't do keep-groups here).
    if pc and engine_is_podman(runner):
        return [pc]
    # Real docker engine → the compose plugin, then the standalone v2+ binary.
    if docker:
        if runner.succeeds([docker, "compose", "version"]):
            banner = runner.capture([docker, "compose", "version"])
            major = _compose_major(banner)
            if major is None or major >= 2:
                return [docker, "compose"]
            tried.append(f"`docker compose` reports v{major} (v2+ required): {banner!r}")
        else:
            tried.append(f"`{docker} compose version` did not exit 0 (no Compose v2 plugin)")
    else:
        tried.append("no `docker` found (PATH or the platform's usual install dirs)")
    if dc_standalone:
        banner = runner.capture([dc_standalone, "version", "--short"])
        major = _compose_major(banner)
        if major and major >= 2:
            return [dc_standalone]
        tried.append(f"standalone `docker-compose` is v{major} (v2+ required): {banner!r}")
    else:
        tried.append("no standalone `docker-compose` found")
    # Last resort: podman-compose even if the engine probe was inconclusive.
    if pc:
        return [pc]
    tried.append("no `podman-compose` found")
    raise NoComposeProvider(
        "no Compose v2+ provider found. The compose files use v2-only features that "
        "legacy docker-compose v1 cannot parse.\nprobed: " + "; ".join(tried),
        hint=install_hint(),
    )

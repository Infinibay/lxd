"""Typed choices shared across the CLI. Kept free of any I/O or Typer imports."""

from __future__ import annotations

from enum import Enum


class Runtime(str, Enum):
    """Container runtime + compose provider selection (`--runtime`)."""

    auto = "auto"
    docker = "docker"
    podman = "podman"


class EngineKind(str, Enum):
    """Identity test-directory engines (`iby engine <kind> …`).

    The value maps 1:1 to the backend `IdentityProviderType`:
      ldap → LDAP, ad → ACTIVE_DIRECTORY.
    """

    ldap = "ldap"
    ad = "ad"


class GpuVendor(str, Enum):
    """Detected host GPU vendor for the infinigpu render path.

    NVIDIA-only for now (owner: other vendors — AMD/Intel — come later). `none`
    means no supported GPU was detected.
    """

    nvidia = "nvidia"
    none = "none"


class InfiniserviceMode(str, Enum):
    """Guest-agent build control on `iby up` (`--infiniservice {auto,skip,rebuild}`).

    Collapses dev.sh's two separate flags --skip-infiniservice / --rebuild-infiniservice.
    """

    auto = "auto"
    skip = "skip"
    rebuild = "rebuild"

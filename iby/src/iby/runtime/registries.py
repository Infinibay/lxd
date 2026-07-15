"""Podman docker.io short-name resolution.

Podman (incl. the podman-docker shim) does not default bare image names like
`postgres:16-bookworm` to docker.io the way Docker does, so pulls fail with
"short-name … did not resolve to an alias". These helpers add an
unqualified-search-registries drop-in — the user-level one (no sudo) and, for the
rootful/KVM path, the /etc drop-in. Ports dev.sh `ensure_podman_registries` /
`ensure_root_registries`.
"""

from __future__ import annotations

import os
import shlex
from pathlib import Path

from ..core.context import AppContext

_LINE = 'unqualified-search-registries = ["docker.io"]'


def _user_conf() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "containers" / "registries.conf"


def registries_configured() -> bool:
    """True if the user-level registries.conf already resolves docker.io short-names."""
    conf = _user_conf()
    return conf.exists() and "unqualified-search-registries" in conf.read_text()


def ensure_podman_registries(ctx: AppContext) -> None:
    """Add the user-level drop-in if absent (no sudo). Idempotent."""
    if registries_configured():
        return
    conf = _user_conf()
    ctx.console.info(f"podman detected → enabling docker.io short-name resolution ({conf})")
    if ctx.dry_run:
        return
    conf.parent.mkdir(parents=True, exist_ok=True)
    if conf.exists():
        # Prepend so the top-level key never lands inside an existing [[registry]] table.
        conf.write_text(f"{_LINE}\n\n" + conf.read_text())
    else:
        conf.write_text(f"{_LINE}\n")


def ensure_root_registries(ctx: AppContext) -> None:
    """Add the /etc drop-in for rootful podman (needs sudo). Idempotent."""
    dropin = "/etc/containers/registries.conf.d/00-infinibay-dockerio.conf"
    if ctx.dry_run:  # keep --dry-run sudo-free (the probe below would sudo)
        ctx.console.debug(f"dry-run: would ensure rootful podman registries drop-in ({dropin})")
        return
    if ctx.runner.succeeds(["test", "-f", dropin], sudo=True):
        return
    ctx.console.info(f"enabling docker.io short-name resolution for rootful podman ({dropin})")
    # Single sudo sh -c so the mkdir + write happen atomically as root (no stdin pipe).
    script = f'mkdir -p /etc/containers/registries.conf.d && printf "%s\\n" {shlex.quote(_LINE)} > {shlex.quote(dropin)}'
    ctx.runner.run(["sh", "-c", script], sudo=True, error="failed to write rootful podman registries drop-in")

"""The infiniservice guest-agent binary. Port of dev.sh infiniservice_built / build.

The backend serves the compiled agent to guests from the shared infinibay_base
volume; a fresh checkout (or a `down -v`/`clean` that wiped it) has none, so guests
would 404 the agent. `built()` is a cheap file probe (namespace-correct via
engine sudo); `build()` cross-compiles it (Windows .exe + Linux ELF) — slow.
"""

from __future__ import annotations

from ..core.context import AppContext
from ..runtime.compose import StackRuntime
from . import repos

# deploy.sh writes the Linux ELF + Windows .exe together, so the Linux one is a
# reliable "already compiled?" signal. Path is relative to the volume root.
_BUILT_MARKER = "infiniservice/binaries/linux/infiniservice"


def built(ctx: AppContext, rt: StackRuntime) -> bool:
    """True iff the agent is already compiled into the infinibay_base volume."""
    sudo = rt.engine_sudo
    names = ctx.runner.capture(["docker", "volume", "ls", "--format", "{{.Name}}"], sudo=sudo).splitlines()
    vol = next((n for n in names if n.endswith("_infinibay_base")), "")
    if not vol:
        return False
    mp = ctx.runner.capture(["docker", "volume", "inspect", "-f", "{{ .Mountpoint }}", vol], sudo=sudo)
    if not mp:
        return False
    return ctx.runner.succeeds(["test", "-f", f"{mp}/{_BUILT_MARKER}"], sudo=sudo)


def build(ctx: AppContext, rt: StackRuntime) -> None:
    """Cross-compile the agent into infinibay_base via the builders profile. Slow."""
    repos.clone_one(ctx, "infiniservice")
    ctx.console.info("cross-compiling infiniservice (Windows .exe + Linux ELF)… this is slow.")
    rt.compose("--profile", "builders", "run", "--rm", "--build", "infiniservice-builder")

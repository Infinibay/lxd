"""First-run setup TUI bridge. Port of dev.sh setup_needed / run_setup_tui.

The Phase A TUI (setup-tui/) collects pre-boot config, writes the env file, and
appends SETUP_DONE=1. It runs BEFORE the env file is read so its values take
effect this run. Prefers host Node; falls back to an ephemeral node:20 container.
"""

from __future__ import annotations

import os
import sys

from ..core import dotenv
from ..core.context import AppContext
from ..core.errors import IbyError
from ..runtime import detect
from . import lan


def setup_needed(ctx: AppContext) -> bool:
    """True when the SETUP_DONE marker is absent AND this is an interactive TTY."""
    if os.environ.get("SETUP_SKIP", "0") == "1":
        return False
    if not sys.stdin.isatty():
        return False
    return dotenv.get_value(ctx.env_path, "SETUP_DONE") != "1"


def run_setup_tui(ctx: AppContext, *, reconfigure: bool = False) -> None:
    """Run the setup-tui (host Node, else a node:20 container). Interactive."""
    project = ctx.require_project_dir()
    tui_dir = project / "setup-tui"
    host_ip = lan.detect_host_ip(ctx)
    extra = ["--reconfigure"] if reconfigure else []

    if detect.has("node"):
        if not (tui_dir / "node_modules").is_dir():
            ctx.console.info("installing setup-tui dependencies (first run)…")
            if not ctx.runner.succeeds(
                ["npm", "install", "--no-audit", "--no-fund", "--loglevel=error"], cwd=tui_dir
            ):
                raise IbyError("setup-tui dependency install failed")
        ctx.runner.run(
            ["node", "setup-tui/src/index.js", "--env-file", ctx.env_file_name, "--host-ip", host_ip, *extra],
            cwd=project,
            error="setup cancelled",
        )
        return

    ctx.console.info("host Node not found — running the setup TUI in a node:20 container")
    inner = (
        "npm install --no-audit --no-fund --loglevel=error && "
        f"node src/index.js --env-file /work/{ctx.env_file_name} --host-ip {host_ip} "
        + (" ".join(extra))
    )
    ctx.runner.run(
        [detect.container_cli(), "run", "--rm", "-it", "-v", f"{project}:/work", "-w", "/work/setup-tui",
         "docker.io/library/node:20", "sh", "-lc", inner],
        error="setup cancelled",
    )

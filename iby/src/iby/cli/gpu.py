"""GPU commands: `iby gpu status` · `iby gpu setup`. NVIDIA-only for now.

Inspect + configure the host GPU for the infinigpu render path. `setup` performs
the privileged prerequisites (generate the NVIDIA CDI spec) transparently —
explaining what/why/which files and asking for sudo — without starting the stack.
"""

from __future__ import annotations

import typer

from ..core.context import AppContext
from ..services import gpu as gpu_svc

gpu_app = typer.Typer(
    name="gpu",
    help="Inspect + configure the host GPU for the infinigpu render path (NVIDIA).",
    no_args_is_help=True,
)


@gpu_app.command("status")
def status(ctx: typer.Context) -> None:
    """Show the detected GPU + render-path readiness (CDI, vfio-user QEMU, device binary)."""
    app_ctx: AppContext = ctx.obj
    gpu_svc.status(app_ctx, app_ctx.repos_dir)


@gpu_app.command("setup")
def setup(ctx: typer.Context) -> None:
    """Ensure the GPU prerequisites (generate the NVIDIA CDI spec) WITHOUT starting the stack.

    Explains each privileged step and asks for sudo before running it.
    """
    app_ctx: AppContext = ctx.obj
    gpu_svc.ensure_gpu_ready(app_ctx, app_ctx.repos_dir)
    app_ctx.console.success("GPU prerequisites ready — start the stack with: iby up --gpu")

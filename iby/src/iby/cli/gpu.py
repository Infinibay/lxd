"""GPU commands: `iby gpu status` · `iby gpu setup`. NVIDIA-only for now.

Inspect + configure the host GPU for the infinigpu render path. `setup` performs
the privileged prerequisites (generate the NVIDIA CDI spec) transparently —
explaining what/why/which files and asking for sudo — without starting the stack.
"""

from __future__ import annotations

import typer

from ..core.context import AppContext
from ..services import gpu as gpu_svc
from ..services import stack as stack_svc

gpu_app = typer.Typer(
    name="gpu",
    help="Inspect + configure the host GPU for the infinigpu render path (NVIDIA).",
    no_args_is_help=True,
)


@gpu_app.command("status")
def status(ctx: typer.Context) -> None:
    """Show the detected GPU + render-path readiness (CDI + built render artifacts)."""
    app_ctx: AppContext = ctx.obj
    rt = stack_svc.prepare_stack(app_ctx)
    gpu_svc.status(app_ctx, rt)


@gpu_app.command("setup")
def setup(ctx: typer.Context) -> None:
    """Ensure the GPU prerequisites (NVIDIA CDI spec + built render artifacts) WITHOUT
    starting the stack. Explains each privileged step and asks for sudo before running it.
    """
    app_ctx: AppContext = ctx.obj
    # want_gpu=True so the compose set includes the GPU override that DEFINES the
    # infinigpu-builder service (else `build` runs against a set missing it).
    rt = stack_svc.prepare_stack(app_ctx, want_gpu=True)
    gpu_svc.ensure_gpu_ready(app_ctx, rt)
    app_ctx.console.success("GPU prerequisites ready — start the stack with: iby up --gpu")


@gpu_app.command("build")
def build(ctx: typer.Context) -> None:
    """Build the container-native render artifacts (vfio-user QEMU + device server) into
    the shared volume, ABI-matched to the backend container. Slow the first time."""
    app_ctx: AppContext = ctx.obj
    # want_gpu=True so the compose set includes the GPU override that DEFINES the
    # infinigpu-builder service.
    rt = stack_svc.prepare_stack(app_ctx, want_gpu=True)
    gpu_svc.build(app_ctx, rt)
    app_ctx.console.success("GPU render artifacts built into the infinigpu_build volume.")

"""`iby infiniservice …` — the Rust in-guest agent binary the backend serves."""

from __future__ import annotations

import typer

from ..core.context import AppContext
from ..services import infiniservice as infsvc
from ..services import stack

app = typer.Typer(no_args_is_help=True, help="Build/inspect the infiniservice guest agent.")


@app.command("build")
def build(ctx: typer.Context) -> None:
    """Cross-compile the agent (Windows .exe + Linux ELF) into the shared volume."""
    stack.build_infiniservice(ctx.obj)


@app.command("status")
def status(ctx: typer.Context) -> None:
    """Report whether the agent is already compiled in the infinibay_base volume."""
    app_ctx: AppContext = ctx.obj
    rt = stack.prepare_stack(app_ctx)
    if infsvc.built(app_ctx, rt):
        app_ctx.console.success("infiniservice guest agent is compiled in the infinibay_base volume.")
    else:
        app_ctx.console.warn("infiniservice guest agent NOT built — run `iby infiniservice build`.")

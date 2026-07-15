"""Dev-stack verbs: up · down · restart · logs · status · exec · pull · clean.

Thin Typer layer — parse flags, delegate to services.stack, render nothing itself.
Registered directly on the root app (the daily-driver hot path). Unknown options
pass through to the underlying compose call (see context_settings in cli/__init__).
"""

from __future__ import annotations

from typing import Optional

import typer

from ..core.context import AppContext
from ..models.enums import InfiniserviceMode
from ..services import stack


def up(
    ctx: typer.Context,
    kvm: Optional[bool] = typer.Option(
        None, "--kvm/--no-kvm", help="Force hypervisor (KVM) on/off. Default: auto-detect /dev/kvm."
    ),
    sandbox: Optional[bool] = typer.Option(
        None, "--sandbox/--no-sandbox", help="QEMU seccomp sandbox on/off. Default off (VMs boot on rootless podman)."
    ),
    cluster: bool = typer.Option(
        False, "--cluster/--no-cluster", help="Add emulated compute nodes (node-1/node-2)."
    ),
    mtls: Optional[bool] = typer.Option(
        None, "--mtls/--no-mtls", help="Cluster mTLS ops server (:4433) for real remote nodes. Sticky."
    ),
    reconfigure: bool = typer.Option(
        False, "--reconfigure", help="Re-run the setup TUI (preserves secrets), then start."
    ),
    infiniservice: InfiniserviceMode = typer.Option(
        InfiniserviceMode.auto, "--infiniservice", help="Guest-agent build: auto | skip | rebuild."
    ),
    skip_infiniservice: bool = typer.Option(False, "--skip-infiniservice", hidden=True),
    rebuild_infiniservice: bool = typer.Option(False, "--rebuild-infiniservice", hidden=True),
    build: bool = typer.Option(True, "--build/--no-build", help="Build images before starting."),
    detach: bool = typer.Option(False, "-d", "--detach", help="Run in the background."),
) -> None:
    """Bring the dev stack online (clone → build → migrate → start). KVM auto-detected."""
    app_ctx: AppContext = ctx.obj
    mode = infiniservice
    if rebuild_infiniservice:  # hidden back-compat aliases
        mode = InfiniserviceMode.rebuild
    elif skip_infiniservice:
        mode = InfiniserviceMode.skip
    if sandbox is True:
        app_ctx.console.info("QEMU seccomp sandbox: ON (--sandbox)")
    elif sandbox is False:
        app_ctx.console.info("QEMU seccomp sandbox: OFF (--no-sandbox, default)")
    stack.up(
        app_ctx,
        want_kvm=kvm,
        want_cluster=cluster,
        want_mtls=mtls,
        want_reconfigure=reconfigure,
        sandbox=sandbox,
        infiniservice_mode=mode,
        build=build,
        detach=detach,
        passthrough=list(ctx.args),
    )


def down(
    ctx: typer.Context,
    volumes: bool = typer.Option(False, "-v", "--volumes", help="Also delete volumes (db, node_modules, …)."),
) -> None:
    """Stop the dev stack (keeps images; -v drops volumes)."""
    extra = (["-v"] if volumes else []) + list(ctx.args)
    stack.down(ctx.obj, extra)


def restart(ctx: typer.Context) -> None:
    """Restart the whole stack, or named service(s)."""
    stack.restart(ctx.obj, list(ctx.args))


def logs(
    ctx: typer.Context,
    tail: Optional[int] = typer.Option(None, "--tail", help="Show the last N lines before following."),
) -> None:
    """Follow container logs (optionally one or more services)."""
    args = (["--tail", str(tail)] if tail is not None else []) + list(ctx.args)
    stack.logs(ctx.obj, args)


def status(ctx: typer.Context) -> None:
    """Show stack container status (compose ps)."""
    stack.status(ctx.obj, list(ctx.args))


def exec_cmd(ctx: typer.Context, service: str = typer.Argument(..., help="Service to exec into.")) -> None:
    """Exec a command inside a running stack container (`iby exec backend -- bash`)."""
    stack.exec_service(ctx.obj, service, list(ctx.args))


def pull(ctx: typer.Context) -> None:
    """Fast-forward every app repo to origin (never triggers the setup wizard)."""
    stack.pull(ctx.obj)


def clean(ctx: typer.Context) -> None:
    """Nuke: volumes + locally-built images + builder volume (= down --purge)."""
    stack.clean(ctx.obj)

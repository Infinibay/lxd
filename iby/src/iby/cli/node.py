"""`iby node …` — run THIS host as a compute node of a remote master."""

from __future__ import annotations

from typing import Optional

import typer

from ..services import node

node_app = typer.Typer(no_args_is_help=True, help="Run this host as a compute node of a remote master.")

_PASSTHRU = {"allow_extra_args": True, "ignore_unknown_options": True}


@node_app.command("join")
def join(
    ctx: typer.Context,
    master: Optional[str] = typer.Argument(None, help="Master IP or URL (bare IP → http://<ip>:4000). Prompted if omitted."),
    name: Optional[str] = typer.Option(None, "--name", help="Node name (default: this host's hostname)."),
    token: Optional[str] = typer.Option(None, "--token", help="Cluster token (default: the one in .env.docker)."),
    master_cn: Optional[str] = typer.Option(None, "--master-cn", help="Master certificate CN for mTLS (default: master)."),
    mtls: bool = typer.Option(True, "--mtls/--no-mtls", help="Heartbeat over mutual TLS (default). --no-mtls = token mode."),
    kvm: bool = typer.Option(False, "--kvm", help="Give the node /dev/kvm so a migrated VM can boot here (opt-in)."),
    reenroll: bool = typer.Option(False, "--reenroll", "--force", help="Wipe an existing cert and pair again."),
    no_start: bool = typer.Option(False, "--no-start", help="Enroll only; don't start the heartbeat."),
) -> None:
    """Enroll this host as a compute node (SAS pairing) and start the heartbeat."""
    node.join(
        ctx.obj,
        master_url=master or "",
        name=name or "",
        token=token or "",
        mtls=mtls,
        master_cn=master_cn or "",
        kvm=kvm,
        reenroll=reenroll,
        no_start=no_start,
    )


@node_app.command("up")
def up(ctx: typer.Context, kvm: bool = typer.Option(False, "--kvm", help="Start with the KVM overlay (persisted).")) -> None:
    """Start the compute-node agent."""
    node.node_cmd(ctx.obj, "up", kvm=kvm)


@node_app.command("down", context_settings=_PASSTHRU)
def down(ctx: typer.Context) -> None:
    """Stop the compute-node agent."""
    node.node_cmd(ctx.obj, "down", rest=list(ctx.args))


@node_app.command("stop", hidden=True, context_settings=_PASSTHRU)
def stop(ctx: typer.Context) -> None:
    node.node_cmd(ctx.obj, "down", rest=list(ctx.args))


@node_app.command("restart")
def restart(ctx: typer.Context, kvm: bool = typer.Option(False, "--kvm")) -> None:
    """Restart the compute-node agent container."""
    node.node_cmd(ctx.obj, "restart", kvm=kvm)


@node_app.command("logs", context_settings=_PASSTHRU)
def logs(ctx: typer.Context) -> None:
    """Follow the node-agent logs."""
    node.node_cmd(ctx.obj, "logs", rest=list(ctx.args))


@node_app.command("status")
def status(ctx: typer.Context) -> None:
    """Show the node-agent container status."""
    node.node_cmd(ctx.obj, "status")

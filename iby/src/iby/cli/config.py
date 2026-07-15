"""`iby config …` — first-run wizard + effective configuration."""

from __future__ import annotations

import typer

from ..services import config

config_app = typer.Typer(no_args_is_help=True, help="First-run wizard + env-file configuration.")


@config_app.command("reconfigure")
def reconfigure(ctx: typer.Context) -> None:
    """Re-run the setup TUI (preserves secrets) without starting the stack."""
    config.reconfigure(ctx.obj)


@config_app.command("show")
def show(ctx: typer.Context) -> None:
    """Print the effective config with secrets masked."""
    config.show(ctx.obj)


@config_app.command("get")
def get(ctx: typer.Context, key: str = typer.Argument(..., help="Env key to read.")) -> None:
    """Print one config value."""
    config.get(ctx.obj, key)


@config_app.command("set")
def set_(ctx: typer.Context, assignment: str = typer.Argument(..., help="KEY=VALUE to upsert.")) -> None:
    """Upsert a KEY=VALUE into the env file."""
    config.set_value(ctx.obj, assignment)


@config_app.command("edit")
def edit(ctx: typer.Context) -> None:
    """Open the env file in $EDITOR."""
    config.edit(ctx.obj)


@config_app.command("lan")
def lan(ctx: typer.Context) -> None:
    """Show the LAN-access overrides iby would apply on `up`."""
    config.lan_cmd(ctx.obj)

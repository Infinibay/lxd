"""`iby engine …` — auxiliary Identity test directories (LDAP + Active Directory).

Canonical form is `iby engine <kind> <verb>` (each engine exposes the full
lifecycle). `iby deploy engine <kind>` is a documented alias of `<kind> up`.
"""

from __future__ import annotations

import typer

from ..core.context import AppContext
from ..services import identity

engine_app = typer.Typer(no_args_is_help=True, help="Identity test engines (LDAP + Active Directory).")


@engine_app.command("ls")
def ls(ctx: typer.Context) -> None:
    """List the known engines and whether each is running."""
    identity.ls(ctx.obj)


def _kind_app(kind: str, label: str) -> typer.Typer:
    sub = typer.Typer(no_args_is_help=True, help=f"Manage the {label} test engine.")

    @sub.command("up")
    def up(
        ctx: typer.Context,
        seed: bool = typer.Option(True, "--seed/--no-seed", help="Seed users/groups after it is healthy."),
        publish_ports: bool = typer.Option(
            False, "--publish-ports", help="Also publish directory ports on the host (for host tools / guest join)."
        ),
    ) -> None:
        """Start the engine, wait until healthy, seed, and print the paste-ready config."""
        identity.up(ctx.obj, kind, seed=seed, publish=publish_ports)

    @sub.command("down")
    def down(
        ctx: typer.Context,
        volumes: bool = typer.Option(False, "-v", "--volumes", help="Also drop its data volumes (clean reseed)."),
    ) -> None:
        """Stop the engine (that project only)."""
        identity.down(ctx.obj, kind, volumes=volumes)

    @sub.command("status")
    def status(ctx: typer.Context) -> None:
        """Show container state + a live directory bind probe."""
        identity.status(ctx.obj, kind)

    @sub.command("seed")
    def seed(
        ctx: typer.Context,
        memberof: bool = typer.Option(False, "--memberof", help="(LDAP) also apply the memberOf overlay."),
    ) -> None:
        """(Re)apply the seed users/groups. Idempotent."""
        identity.seed(ctx.obj, kind, memberof=memberof)

    @sub.command("config")
    def config(ctx: typer.Context) -> None:
        """Print the ready-to-paste IdentityProvider fields for the UI."""
        identity.config(ctx.obj, kind)

    @sub.command("logs")
    def logs(ctx: typer.Context) -> None:
        """Follow the engine's container logs."""
        identity.logs(ctx.obj, kind)

    return sub


engine_app.add_typer(_kind_app("ldap", "OpenLDAP"), name="ldap")
engine_app.add_typer(_kind_app("ad", "Samba Active Directory"), name="ad")


# ── `iby deploy engine <kind>` alias (honours the maintainer's original hint) ──
deploy_app = typer.Typer(no_args_is_help=True, help="Deploy shortcuts. `iby deploy engine ldap` = `iby engine ldap up`.")
_deploy_engine = typer.Typer(no_args_is_help=True, help="Bring up an identity test engine.")


@_deploy_engine.command("ldap")
def _deploy_ldap(ctx: typer.Context) -> None:
    """Alias of `iby engine ldap up`."""
    identity.up(ctx.obj, "ldap")


@_deploy_engine.command("ad")
def _deploy_ad(ctx: typer.Context) -> None:
    """Alias of `iby engine ad up`."""
    identity.up(ctx.obj, "ad")


deploy_app.add_typer(_deploy_engine, name="engine")

"""System commands: version · doctor · completion. Registered on the root app."""

from __future__ import annotations

import typer

from .. import __version__
from ..core.context import AppContext
from ..core.errors import NoComposeProvider
from ..runtime import detect
from ..services import doctor as doctor_svc


def version(ctx: typer.Context) -> None:
    """Print iby + dev-stack versions and the resolved container/compose provider."""
    app_ctx: AppContext = ctx.obj
    con = app_ctx.console
    con.plain(f"iby {__version__}")
    if app_ctx.project_dir:
        vfile = app_ctx.project_dir / "VERSION"
        if vfile.exists():
            con.plain(f"dev-stack {vfile.read_text().strip()}   ({app_ctx.project_dir})")
    try:
        con.plain(f"compose provider: {' '.join(detect.resolve_compose(app_ctx.runner))}")
    except NoComposeProvider:
        con.plain("compose provider: [yellow]none found[/]")


def doctor(
    ctx: typer.Context,
    fix: bool = typer.Option(False, "--fix", help="Apply the no-sudo remedies (podman registries)."),
) -> None:
    """Preflight the host: runtime, compose v2, /dev/kvm, kernel modules, groups."""
    app_ctx: AppContext = ctx.obj
    if not doctor_svc.run(app_ctx, fix=fix):
        raise typer.Exit(1)


def completion(
    ctx: typer.Context,
    shell: str = typer.Argument("bash", help="Shell to emit a completion script for: bash | zsh | fish."),
) -> None:
    """Emit a shell-completion script (`iby completion zsh >> ~/.zshrc`)."""
    from click.shell_completion import get_completion_class

    from . import typer_app  # lazy import to avoid a circular import at module load

    comp_cls = get_completion_class(shell)
    if comp_cls is None:
        raise typer.BadParameter(f"unsupported shell '{shell}' (try: bash, zsh, fish)")
    command = typer.main.get_command(typer_app)
    completer = comp_cls(command, {}, "iby", "_IBY_COMPLETE")
    app_ctx: AppContext = ctx.obj
    app_ctx.console.plain(completer.source())

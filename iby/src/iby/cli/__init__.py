"""Root Typer app, global options, and the top-level error boundary.

`typer_app` is the Typer instance (introspected by completion + `python -m iby`).
`app` is the console-script entry point: it runs `typer_app` and turns an
`IbyError` into a clean message + stable exit code instead of a traceback.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

import typer

from .. import __version__
from ..core.console import Console
from ..core.context import AppContext
from ..core.errors import IbyError
from ..models.enums import Runtime
from . import config as config_cli
from . import engine as engine_cli
from . import infiniservice as infiniservice_cli
from . import node as node_cli
from . import repos as repos_cli
from . import stack as stack_cli
from . import system

typer_app = typer.Typer(
    name="iby",
    help="Infinibay unified deploy + admin CLI. Replaces dev.sh — run `iby doctor` first.",
    no_args_is_help=True,
    add_completion=True,
    rich_markup_mode="rich",
    pretty_exceptions_enable=False,  # we own the error boundary (see app())
)


def _version_callback(value: bool) -> None:
    # Eager so it fires during option parsing, before the "Missing command" check.
    if value:
        typer.echo(f"iby {__version__}")
        raise typer.Exit()


@typer_app.callback()
def main(
    ctx: typer.Context,
    project_dir: Optional[Path] = typer.Option(
        None, "--project-dir", envvar="IBY_PROJECT_DIR",
        help="lxd repo root (auto-discovered by walking up for docker-compose.yml + VERSION).",
    ),
    env_file: Optional[str] = typer.Option(
        None, "--env-file", envvar="IBY_ENV_FILE", help="Override the env file (default .env.docker).",
    ),
    repos_dir: Optional[Path] = typer.Option(
        None, "--repos-dir", envvar="REPOS_DIR", help="Where the four app repos are cloned (default ./repos).",
    ),
    repo_ref: str = typer.Option("main", "--ref", envvar="REPO_REF", help="Git ref for the app repos."),
    runtime: Runtime = typer.Option(
        Runtime.auto, "--runtime", envvar="IBY_RUNTIME", help="Force the container runtime / compose provider.",
    ),
    dry_run: bool = typer.Option(False, "--dry-run", help="Print the exact commands, execute nothing."),
    assume_yes: bool = typer.Option(False, "-y", "--yes", help="Assume yes for confirmations."),
    debug: bool = typer.Option(False, "--debug", help="Verbose: echo every command before running it."),
    quiet: bool = typer.Option(False, "-q", "--quiet", help="Suppress informational output."),
    no_color: bool = typer.Option(False, "--no-color", envvar="NO_COLOR", help="Disable ANSI color."),
    show_version: Optional[bool] = typer.Option(
        None, "--version", callback=_version_callback, is_eager=True, help="Print version and exit.",
    ),
) -> None:
    ctx.obj = AppContext.build(
        project_dir=project_dir,
        env_file=env_file,
        repos_dir=repos_dir,
        repo_ref=repo_ref,
        runtime=runtime,
        dry_run=dry_run,
        assume_yes=assume_yes,
        debug=debug,
        quiet=quiet,
        no_color=no_color,
    )


# ── command registration ─────────────────────────────────────────────────────
# Unknown options on the hot-path verbs pass through to the underlying compose call
# (e.g. `iby up --remove-orphans`, `iby exec backend -- bash`).
_PASSTHRU = {"allow_extra_args": True, "ignore_unknown_options": True}

# Dev-stack hot path (top-level verbs).
typer_app.command("up", context_settings=_PASSTHRU)(stack_cli.up)
typer_app.command("down", context_settings=_PASSTHRU)(stack_cli.down)
typer_app.command("restart", context_settings=_PASSTHRU)(stack_cli.restart)
typer_app.command("logs", context_settings=_PASSTHRU)(stack_cli.logs)
typer_app.command("status", context_settings=_PASSTHRU)(stack_cli.status)
typer_app.command("ps", hidden=True, context_settings=_PASSTHRU)(stack_cli.status)  # alias
typer_app.command("exec", context_settings=_PASSTHRU)(stack_cli.exec_cmd)
typer_app.command("pull")(stack_cli.pull)
typer_app.command("clean")(stack_cli.clean)

# Groups.
typer_app.add_typer(engine_cli.engine_app, name="engine")
typer_app.add_typer(engine_cli.deploy_app, name="deploy")
typer_app.add_typer(node_cli.node_app, name="node")
typer_app.add_typer(config_cli.config_app, name="config")
typer_app.add_typer(repos_cli.repos_app, name="repos")
typer_app.add_typer(infiniservice_cli.app, name="infiniservice")

# System.
typer_app.command("version")(system.version)
typer_app.command("doctor")(system.doctor)
typer_app.command("completion")(system.completion)


def app() -> None:
    """Console-script entry point with the top-level IbyError boundary."""
    try:
        typer_app()
    except IbyError as exc:
        con = Console()
        con.error(exc.message)
        if exc.hint:
            con.warn(exc.hint)
        raise SystemExit(exc.exit_code)
    except KeyboardInterrupt:
        raise SystemExit(130)

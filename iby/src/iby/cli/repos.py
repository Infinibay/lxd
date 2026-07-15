"""`iby repos …` — the four app source repos (`pull` is also a top-level verb)."""

from __future__ import annotations

import typer
from rich.table import Table

from ..core.context import AppContext
from ..services import repos

repos_app = typer.Typer(no_args_is_help=True, help="The four app source repos (backend/frontend/infinization/infiniservice).")

_STATE_STYLE = {"clean": "green", "dirty": "yellow", "missing": "red"}


def _render(ctx: AppContext, *, with_path: bool) -> None:
    table = Table(title="repos", title_style="bold cyan")
    table.add_column("repo", style="bold")
    table.add_column("ref")
    table.add_column("state")
    if with_path:
        table.add_column("path", overflow="fold")
    for name, ref, state, path in repos.repo_rows(ctx):
        style = _STATE_STYLE.get(state, "white")
        row = [name, ref, f"[{style}]{state}[/]"]
        if with_path:
            row.append(path)
        table.add_row(*row)
    ctx.console.render(table)


@repos_app.command("status")
def status(ctx: typer.Context) -> None:
    """Per-repo git ref + clean/dirty/missing state."""
    _render(ctx.obj, with_path=False)


@repos_app.command("list")
def list_(ctx: typer.Context) -> None:
    """Repos, refs, and their checkout paths."""
    _render(ctx.obj, with_path=True)


@repos_app.command("clone")
def clone(ctx: typer.Context) -> None:
    """Clone any missing repo (frontend --recurse-submodules)."""
    repos.clone_all(ctx.obj)

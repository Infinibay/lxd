"""AppContext — the resolved, per-invocation state every command receives.

Built once in the root Typer callback from the global flags, then handed to
services via `ctx.obj`. Owns project-root discovery (so a uvx-installed `iby`
with no script directory still finds the lxd repo) plus the shared Console/Runner.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from ..models.enums import Runtime
from .console import Console
from .errors import ProjectNotFound
from .process import Runner

# A directory is the lxd project root iff it holds BOTH of these — enough to tell
# it apart from ./repos or a random parent.
PROJECT_SENTINELS = ("docker-compose.yml", "VERSION")


def discover_project_dir(explicit: Path | None) -> Path | None:
    """--project-dir → $IBY_PROJECT_DIR → walk up from cwd for the sentinels."""
    if explicit is not None:
        return explicit.resolve()
    env = os.environ.get("IBY_PROJECT_DIR")
    if env:
        return Path(env).resolve()
    cur = Path.cwd().resolve()
    for d in (cur, *cur.parents):
        if all((d / s).exists() for s in PROJECT_SENTINELS):
            return d
    return None


@dataclass
class AppContext:
    project_dir: Path | None
    env_file_name: str
    repos_dir_opt: Path | None
    repo_ref: str
    runtime: Runtime
    dry_run: bool
    assume_yes: bool
    debug: bool
    quiet: bool
    no_color: bool
    console: Console
    runner: Runner

    @classmethod
    def build(
        cls,
        *,
        project_dir: Path | None,
        env_file: str | None,
        repos_dir: Path | None,
        repo_ref: str,
        runtime: Runtime,
        dry_run: bool,
        assume_yes: bool,
        debug: bool,
        quiet: bool,
        no_color: bool,
    ) -> "AppContext":
        console = Console()
        console.configure(no_color=no_color, debug=debug, quiet=quiet, assume_yes=assume_yes)
        runner = Runner(console=console, dry_run=dry_run)
        return cls(
            project_dir=discover_project_dir(project_dir),
            env_file_name=env_file or ".env.docker",
            repos_dir_opt=repos_dir,
            repo_ref=repo_ref or "main",
            runtime=runtime,
            dry_run=dry_run,
            assume_yes=assume_yes,
            debug=debug,
            quiet=quiet,
            no_color=no_color,
            console=console,
            runner=runner,
        )

    def require_project_dir(self) -> Path:
        if self.project_dir is None:
            raise ProjectNotFound(
                "could not find the Infinibay lxd project root "
                f"(a directory holding {' + '.join(PROJECT_SENTINELS)})",
                hint="cd into your lxd checkout, or pass --project-dir /path/to/lxd",
            )
        return self.project_dir

    @property
    def env_path(self) -> Path:
        return self.require_project_dir() / self.env_file_name

    @property
    def repos_dir(self) -> Path:
        if self.repos_dir_opt is not None:
            p = self.repos_dir_opt
            return p if p.is_absolute() else (self.require_project_dir() / p)
        return self.require_project_dir() / "repos"

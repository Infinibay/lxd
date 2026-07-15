"""User-facing output + prompts. The one place that knows about colors/TTY.

Mirrors dev.sh's `c()` / `warn()` / `die()` vocabulary with an `[iby]` prefix, but
adds Rich styling, `--no-color`/`NO_COLOR` handling, `--quiet`/`--debug` levels,
and `--yes`-aware confirmation. Services call these; they never touch stdout directly.
"""

from __future__ import annotations

from rich.console import Console as RichConsole
from rich.prompt import Confirm
from rich.theme import Theme

from .errors import IbyError, UserDeclined

_THEME = Theme(
    {
        "iby.info": "bold cyan",
        "iby.warn": "bold yellow",
        "iby.error": "bold red",
        "iby.ok": "bold green",
        "iby.debug": "dim",
    }
)

_PREFIX = "\\[iby]"  # escaped so Rich renders a literal "[iby]", not a style tag


class Console:
    """Thin wrapper over two Rich consoles (stdout + stderr) plus verbosity state."""

    def __init__(self) -> None:
        self._out = RichConsole(theme=_THEME, highlight=False)
        self._err = RichConsole(theme=_THEME, highlight=False, stderr=True)
        self.assume_yes = False
        self.debug_enabled = False
        self.quiet = False

    def configure(self, *, no_color: bool, debug: bool, quiet: bool, assume_yes: bool) -> None:
        self.assume_yes = assume_yes
        self.debug_enabled = debug
        self.quiet = quiet
        if no_color:
            self._out = RichConsole(theme=_THEME, highlight=False, no_color=True)
            self._err = RichConsole(theme=_THEME, highlight=False, no_color=True, stderr=True)

    # ── streams ──────────────────────────────────────────────────────────────
    # soft_wrap=True: never hard-wrap a log line (rich defaults to 80 cols when
    # output is piped, which would mangle a copy-pasteable command echo).
    def info(self, message: str) -> None:
        if not self.quiet:
            self._out.print(f"[iby.info]{_PREFIX}[/] {message}", soft_wrap=True)

    def warn(self, message: str) -> None:
        self._err.print(f"[iby.warn]{_PREFIX}[/] {message}", soft_wrap=True)

    def error(self, message: str) -> None:
        self._err.print(f"[iby.error]{_PREFIX}[/] {message}", soft_wrap=True)

    def success(self, message: str) -> None:
        if not self.quiet:
            self._out.print(f"[iby.ok]{_PREFIX}[/] {message}", soft_wrap=True)

    def debug(self, message: str) -> None:
        if self.debug_enabled:
            self._err.print(f"[iby.debug]{_PREFIX} {message}[/]", soft_wrap=True)

    def plain(self, message: str = "") -> None:
        """Print without the [iby] prefix (help text, tables, banners)."""
        if not self.quiet:
            self._out.print(message, soft_wrap=True)

    def render(self, renderable: object) -> None:
        """Print a Rich renderable (e.g. a Table) to stdout."""
        if not self.quiet:
            self._out.print(renderable)

    # ── control flow ─────────────────────────────────────────────────────────
    def die(self, message: str, *, exit_code: int = 1, hint: str | None = None) -> "IbyError":
        """Return an IbyError to raise. (Caller writes `raise console.die(...)`.)"""
        return IbyError(message, exit_code=exit_code, hint=hint)

    def confirm(self, prompt: str, *, default: bool = False) -> bool:
        """Ask a yes/no question. `--yes` short-circuits to True (and says so)."""
        if self.assume_yes:
            self.info(f"{prompt} → yes (--yes)")
            return True
        try:
            return Confirm.ask(f"[iby.info]{_PREFIX}[/] {prompt}", default=default)
        except (EOFError, KeyboardInterrupt):
            raise UserDeclined("cancelled")

    def banner(self, title: str, lines: list[str]) -> None:
        if self.quiet:
            return
        self._out.rule(f"[iby.info]{title}[/]")
        for line in lines:
            self._out.print(line)
        self._out.rule()

"""`iby config …` — the first-run wizard + effective configuration of the env file."""

from __future__ import annotations

import os

from rich.table import Table

from ..core import dotenv
from ..core.context import AppContext
from ..core.errors import IbyError
from . import lan, stack, wizard

_SECRET_HINTS = ("PASSWORD", "SECRET", "TOKEN", "HMAC", "TOKENKEY")


def _is_secret(key: str) -> bool:
    k = key.upper()
    return any(h in k for h in _SECRET_HINTS)


def _mask(val: str) -> str:
    if not val:
        return val
    return f"{val[:2]}…" if len(val) > 2 else "…"


def reconfigure(ctx: AppContext) -> None:
    """Re-run the setup TUI (preserving secrets) without starting the stack."""
    env_path = ctx.env_path
    if not env_path.exists():
        example = ctx.require_project_dir() / f"{ctx.env_file_name}.example"
        env_path.write_text(example.read_text())
    stack._ensure_master_env(ctx)
    wizard.run_setup_tui(ctx, reconfigure=True)
    ctx.console.success(f"Reconfigured {ctx.env_file_name}. Run `iby up` to (re)start with the new settings.")


def show(ctx: AppContext) -> None:
    """Print the effective config, secrets masked."""
    vals = dotenv.read_values(ctx.env_path)
    if not vals:
        ctx.console.warn(f"{ctx.env_file_name} is empty or missing — run `iby up` (or `iby config reconfigure`).")
        return
    table = Table(title=ctx.env_file_name, title_style="bold cyan")
    table.add_column("key", style="bold")
    table.add_column("value", overflow="fold")
    for k, v in vals.items():
        table.add_row(k, _mask(v) if _is_secret(k) else v)
    ctx.console.render(table)


def get(ctx: AppContext, key: str) -> None:
    v = dotenv.get_value(ctx.env_path, key)
    if v is None:
        raise IbyError(f"{key} is not set in {ctx.env_file_name}")
    ctx.console.plain(v)


def set_value(ctx: AppContext, assignment: str) -> None:
    if "=" not in assignment:
        raise IbyError("expected KEY=VALUE (e.g. iby config set LOG_LEVEL=debug)")
    key, val = assignment.split("=", 1)
    key = key.strip()
    dotenv.upsert(ctx.env_path, key, val)
    ctx.console.success(f"set {key} in {ctx.env_file_name}")


def edit(ctx: AppContext) -> None:
    editor = os.environ.get("EDITOR") or os.environ.get("VISUAL") or "vi"
    ctx.runner.run([editor, str(ctx.env_path)])


def lan_cmd(ctx: AppContext) -> None:
    """Show the LAN-access env overrides iby would apply on `up` (without starting)."""
    merged = {**os.environ, **dotenv.read_values(ctx.env_path)}
    overrides = lan.configure_lan_access(ctx, merged)
    table = Table(title="LAN access overrides", title_style="bold cyan")
    table.add_column("key", style="bold")
    table.add_column("value", style="green", overflow="fold")
    for k, v in overrides.items():
        table.add_row(k, v)
    ctx.console.render(table)

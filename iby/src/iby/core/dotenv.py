"""Read + edit `.env`-style files (.env.docker / .env.node).

Two write primitives, matching dev.sh exactly:

  * `ensure_key`  — ADD IF ABSENT (dev.sh `ensure_env_key`): seed a default the
    first time, never clobber an operator's later edit.
  * `upsert`      — REWRITE-OR-APPEND (dev.sh `upsert_env`): for operator-toggled
    knobs (mTLS, NODE_KVM) that must persist and override across runs.

Presence is tested with dev.sh's own pattern `^\\s*KEY=` so behaviour is identical.
Reading uses python-dotenv for correct quote/interpolation handling.
"""

from __future__ import annotations

import re
from pathlib import Path

from dotenv import dotenv_values


def read_values(path: Path) -> dict[str, str]:
    """Parse a file into a dict (empty if it doesn't exist)."""
    if not path.exists():
        return {}
    return {k: v for k, v in dotenv_values(path).items() if v is not None}


def get_value(path: Path, key: str) -> str | None:
    """First `KEY=value` in the file (mirrors dev.sh `grep … | head -1 | cut`)."""
    if not path.exists():
        return None
    pattern = re.compile(rf"^\s*{re.escape(key)}=(.*)$")
    for line in path.read_text().splitlines():
        m = pattern.match(line)
        if m:
            return m.group(1)
    return None


def _has_key(path: Path, key: str) -> bool:
    if not path.exists():
        return False
    pattern = re.compile(rf"^\s*{re.escape(key)}=")
    return any(pattern.match(line) for line in path.read_text().splitlines())


def ensure_key(path: Path, key: str, default: str, comment: str | None = None) -> bool:
    """Append `KEY=default` (with an optional comment) only if KEY is absent.

    Returns True if it was added. Idempotent — safe to call on every command.
    """
    if _has_key(path, key):
        return False
    chunk = ""
    if comment:
        chunk += f"\n# {comment}\n"
    chunk += f"{key}={default}\n"
    with path.open("a") as fh:
        fh.write(chunk)
    return True


def upsert(path: Path, key: str, val: str) -> None:
    """Rewrite KEY's line if present, else append it. Persists operator toggles."""
    if path.exists() and _has_key(path, key):
        pattern = re.compile(rf"^(\s*){re.escape(key)}=.*$")
        lines = path.read_text().splitlines(keepends=True)
        out = []
        for line in lines:
            m = pattern.match(line)
            out.append(f"{key}={val}\n" if m else line)
        path.write_text("".join(out))
    else:
        with path.open("a") as fh:
            fh.write(f"{key}={val}\n")

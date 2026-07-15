"""The single choke-point for shelling out.

Every external command (git, compose, docker/podman, lxc) goes through `Runner`. It
centralises what dev.sh repeated by hand:

  * `--dry-run` for MUTATIONS: `run()` echoes the exact resolved argv and executes
    nothing. Read-only probes (`capture`/`succeeds`) always execute — dry-run must
    still see real host state to report what it WOULD do.
  * the sudo + `env VAR=val` prefix for the rootful-podman (KVM) path. `env` is
    placed AFTER sudo so sudo's env_reset can't drop it (dev.sh's `dc()` trick),
    and it works with or without sudo.
  * `cwd` (compose runs from the project root, mirroring dev.sh's `cd`) and
    `extra_env` (computed overrides injected into the child environment).
  * exit-code → `IbyError` mapping, so callers `raise`, never `sys.exit`.
"""

from __future__ import annotations

import os
import shlex
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .console import Console
from .errors import IbyError


@dataclass
class Result:
    argv: list[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0


@dataclass
class Runner:
    console: Console
    dry_run: bool = False
    _env_forward: dict[str, str] = field(default_factory=dict)

    def build(
        self,
        argv: list[str],
        *,
        sudo: bool = False,
        env_forward: dict[str, str] | None = None,
    ) -> list[str]:
        """Prefix `[sudo] [env K=V …]` then the command. Matches dev.sh dc()."""
        cmd: list[str] = []
        if sudo:
            cmd.append("sudo")
        merged = {**self._env_forward, **(env_forward or {})}
        if merged:
            cmd.append("env")
            cmd += [f"{k}={v}" for k, v in merged.items()]
        cmd += [str(a) for a in argv]
        return cmd

    def _exec(
        self,
        cmd: list[str],
        *,
        capture: bool,
        extra_env: dict[str, str] | None,
        cwd: Path | None,
    ) -> Result:
        env = {**os.environ, **extra_env} if extra_env else None
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=capture,
            env=env,
            cwd=str(cwd) if cwd else None,
        )
        return Result(cmd, proc.returncode, proc.stdout or "", proc.stderr or "")

    def run(
        self,
        argv: list[str],
        *,
        sudo: bool = False,
        env_forward: dict[str, str] | None = None,
        extra_env: dict[str, str] | None = None,
        cwd: Path | None = None,
        check: bool = True,
        capture: bool = False,
        error: str | None = None,
    ) -> Result:
        """Run a MUTATING command (honours --dry-run)."""
        cmd = self.build(argv, sudo=sudo, env_forward=env_forward)
        if self.dry_run:
            self.console.info(f"dry-run: {shlex.join(cmd)}")
            return Result(cmd, 0)
        self.console.debug(f"exec: {shlex.join(cmd)}")
        result = self._exec(cmd, capture=capture, extra_env=extra_env, cwd=cwd)
        if check and not result.ok:
            raise IbyError(error or f"command failed ({result.returncode}): {shlex.join(cmd)}")
        return result

    # ── read-only probes: ALWAYS execute, even under --dry-run ────────────────
    def capture(self, argv: list[str], *, sudo: bool = False, cwd: Path | None = None) -> str:
        """Stripped stdout, or "" on failure. For capability detection, not control."""
        cmd = self.build(argv, sudo=sudo)
        return self._exec(cmd, capture=True, extra_env=None, cwd=cwd).stdout.strip()

    def succeeds(self, argv: list[str], *, sudo: bool = False, cwd: Path | None = None) -> bool:
        """True iff the command exits 0. Never raises."""
        cmd = self.build(argv, sudo=sudo)
        return self._exec(cmd, capture=True, extra_env=None, cwd=cwd).ok

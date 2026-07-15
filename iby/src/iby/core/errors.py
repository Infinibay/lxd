"""Error hierarchy with stable process exit codes.

The CLI top-level (`cli/__init__.py`) catches `IbyError`, prints it through the
console, and exits with `.exit_code`. Everything below the CLI raises these
instead of calling `sys.exit`, so services/runtime stay testable and Typer-free.
"""

from __future__ import annotations


class IbyError(Exception):
    """Base class for all expected, user-facing failures.

    `exit_code` is the process status the CLI exits with. `hint` is an optional
    second line with remediation guidance (install command, next step, …).
    """

    exit_code: int = 1

    def __init__(self, message: str, *, exit_code: int | None = None, hint: str | None = None):
        super().__init__(message)
        self.message = message
        self.hint = hint
        if exit_code is not None:
            self.exit_code = exit_code


class UserDeclined(IbyError):
    """Operator answered "no" to a confirmation, or cancelled a prompt."""

    exit_code = 2


class MissingTool(IbyError):
    """A required external binary (docker/podman/git/…) is not on PATH."""

    exit_code = 4


class NoComposeProvider(IbyError):
    """No Compose Spec v2 provider (podman-compose / docker compose v2) found."""

    exit_code = 5


class ProjectNotFound(IbyError):
    """Could not locate the lxd project root (docker-compose.yml + VERSION)."""

    exit_code = 6


class RuntimeUnavailable(IbyError):
    """A required host capability is missing (e.g. /dev/kvm for a --kvm run)."""

    exit_code = 7

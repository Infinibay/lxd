"""StackRuntime — the resolved compose invocation. Port of dev.sh dc().

Holds everything a compose call needs (provider, --env-file, ordered -f overlays,
profiles, sudo, the env-forward for sandbox/mtls, and the child-env overrides) so
services just call `rt.compose("up", "--build")`. The argv it builds mirrors dev.sh
exactly:

    [sudo] [env K=V…] <provider> --env-file <file> -f <base> -f <overlay…> \\
        [--profile p…] <args…>

Run from the project root (cwd) so the compose files' relative paths (./repos,
./docker) resolve the way they did under dev.sh's `cd`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from ..core.context import AppContext
from ..core.process import Result


@dataclass
class StackRuntime:
    ctx: AppContext
    project_dir: Path
    compose_cmd: list[str]
    env_file_name: str
    compose_files: list[str]  # relative filenames, in override order
    engine_sudo: bool = False
    kvm_active: bool = False
    profiles: list[str] = field(default_factory=list)
    env_overrides: dict[str, str] = field(default_factory=dict)  # child env (LAN, …)
    env_forward: dict[str, str] = field(default_factory=dict)  # `env K=V` after sudo
    env: dict[str, str] = field(default_factory=dict)  # merged env view (for port/host reads)

    def _base_argv(self) -> list[str]:
        argv = [*self.compose_cmd, "--env-file", self.env_file_name]
        for f in self.compose_files:
            argv += ["-f", f]
        for p in self.profiles:
            argv += ["--profile", p]
        return argv

    def compose(self, *args: str, check: bool = True, capture: bool = False) -> Result:
        """Run a compose subcommand (e.g. compose('up', '--build')).

        The LAN/host overrides (NEXT_PUBLIC_*, APP_HOST, ALLOWED_ORIGINS, …) MUST be
        forwarded as `env K=V` AFTER sudo — NOT via the child process env. On the
        rootful (KVM) path sudo's env_reset strips the child environment before
        podman-compose interpolates `${VAR}`, so passing them as `extra_env` drops
        them silently and the localhost defaults baked into --env-file win instead
        (this is exactly why remote/LAN access broke). A forwarded var survives sudo
        AND takes precedence over --env-file (verified against podman-compose). The
        explicit env_forward (sandbox/mtls) wins on any key collision.
        """
        forward = {**self.env_overrides, **self.env_forward}
        return self.ctx.runner.run(
            [*self._base_argv(), *args],
            sudo=self.engine_sudo,
            env_forward=forward,
            cwd=self.project_dir,
            check=check,
            capture=capture,
        )

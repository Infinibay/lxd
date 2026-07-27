"""Cross-platform detection of the container engine + Compose v2 provider.

These exist because the bug they pin cannot be reproduced on the machine that fixes it:
`iby doctor` on macOS reported "no Compose v2+ provider found" on a host where Docker
Desktop and `docker compose` were both installed and working. Two independent causes,
each of which alone is enough to produce that report, and each of which is invisible from
Linux — so the only way to keep them fixed is to state them here.
"""

from __future__ import annotations

import os
import platform
import stat

import pytest

from iby.core.errors import NoComposeProvider
from iby.runtime import detect


class FakeRunner:
    """Stands in for `Runner`, answering by exact argv prefix.

    `capture` returns "" for anything unregistered and `succeeds` returns False, which is
    precisely how the real Runner behaves for a command that fails or does not exist —
    the detector must never mistake that silence for a positive answer.
    """

    def __init__(self, *, stdout: dict[tuple[str, ...], str] | None = None,
                 ok: set[tuple[str, ...]] | None = None):
        self.stdout = stdout or {}
        self.ok = ok or set()

    @staticmethod
    def _key(argv: list[str]) -> tuple[str, ...]:
        # Match on the basename so a test does not have to know where `which` found it.
        return (os.path.basename(argv[0]), *argv[1:])

    def capture(self, argv, **_):
        return self.stdout.get(self._key(argv), "")

    def succeeds(self, argv, **_):
        return self._key(argv) in self.ok


@pytest.fixture
def only(monkeypatch):
    """Pretend exactly `tools` are installed, at the given paths."""

    def _only(**tools: str):
        monkeypatch.setattr(detect, "which", lambda t: tools.get(t))
        return tools

    return _only


# ── cause 1: existence was gated on parsing a version banner ────────────────────────

def test_docker_compose_is_accepted_on_an_unparseable_banner(only):
    """`docker compose` exiting 0 IS Compose v2 — there was never a v1 plugin.

    The old code required a `\\d+\\.\\d+` out of the banner and rejected the provider when
    it could not find one. Anything that moves the version out of stdout — a localized
    build, a wrapper that logs to stderr (which `Runner.capture` does not collect) — then
    read as "not installed" while `docker compose` worked perfectly from the same shell.
    """
    only(docker="/usr/local/bin/docker")
    r = FakeRunner(
        stdout={("docker", "version"): "Docker version 27.4.0", ("docker", "compose", "version"): ""},
        ok={("docker", "compose", "version")},
    )
    assert detect.resolve_compose(r) == ["/usr/local/bin/docker", "compose"]


def test_docker_compose_plugin_is_accepted_with_a_vendor_suffix(only):
    only(docker="/usr/local/bin/docker")
    r = FakeRunner(
        stdout={("docker", "compose", "version"): "Docker Compose version v2.39.1-desktop.1"},
        ok={("docker", "compose", "version")},
    )
    assert detect.resolve_compose(r) == ["/usr/local/bin/docker", "compose"]


def test_a_nonzero_exit_is_not_a_provider(only):
    """The exit code is the evidence, so a plugin that is absent must still be absent."""
    only(docker="/usr/local/bin/docker")
    with pytest.raises(NoComposeProvider) as exc:
        detect.resolve_compose(FakeRunner())
    # The failure has to say what was probed; "not found" alone is what sent this bug
    # round-trip to a user on another OS in the first place.
    assert "did not exit 0" in str(exc.value)


def test_legacy_standalone_v1_is_still_rejected(only):
    """The compose files use v2-only features; v1 must not be silently accepted."""
    only(**{"docker-compose": "/usr/bin/docker-compose"})
    r = FakeRunner(stdout={("docker-compose", "version", "--short"): "1.29.2"})
    with pytest.raises(NoComposeProvider):
        detect.resolve_compose(r)


def test_standalone_v2_is_accepted(only):
    only(**{"docker-compose": "/usr/bin/docker-compose"})
    r = FakeRunner(stdout={("docker-compose", "version", "--short"): "v2.24.6"})
    assert detect.resolve_compose(r) == ["/usr/bin/docker-compose"]


# ── cause 2: PATH is a property of the shell, not of the machine ────────────────────

def test_which_finds_docker_desktop_outside_path(monkeypatch, tmp_path):
    """Docker Desktop installs into ~/.docker/bin and appends it to PATH from the shell
    profile, so a non-login shell sees a Mac with "no docker on it"."""
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(detect.shutil, "which", lambda _t: None)  # nothing on PATH
    bindir = tmp_path / ".docker" / "bin"
    bindir.mkdir(parents=True)
    exe = bindir / "docker"
    exe.write_text("#!/bin/sh\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setitem(detect._EXTRA_BIN_DIRS, "Darwin", [bindir])

    assert detect.which("docker") == str(exe)
    assert detect.has("docker") is True
    # And it must be invoked by the path it was found at, or exec fails on the very
    # binary we just reported as present.
    assert detect.container_cli() == str(exe)


def test_which_still_returns_none_when_genuinely_absent(monkeypatch, tmp_path):
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(detect.shutil, "which", lambda _t: None)
    monkeypatch.setitem(detect._EXTRA_BIN_DIRS, "Darwin", [tmp_path])
    assert detect.which("docker") is None
    assert detect.has("docker") is False


def test_path_still_wins_when_it_has_an_answer(monkeypatch):
    monkeypatch.setattr(detect.shutil, "which", lambda t: f"/from/path/{t}")
    assert detect.which("podman") == "/from/path/podman"


# ── the hint has to be usable on the host that reads it ────────────────────────────

def test_install_hint_does_not_tell_a_mac_user_to_run_apt_get(monkeypatch):
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    hint = detect.install_hint()
    assert "apt-get" not in hint
    assert "Docker Desktop" in hint and "brew" in hint


def test_podman_engine_still_prefers_podman_compose(only):
    """Unchanged behaviour, pinned: `docker compose` over a podman socket drops
    keep-groups, which is what gives the rootless container /dev/kvm."""
    only(docker="/usr/bin/docker", **{"podman-compose": "/usr/bin/podman-compose"})
    r = FakeRunner(stdout={("docker", "version"): "Server: Podman Engine\n"})
    assert detect.resolve_compose(r) == ["/usr/bin/podman-compose"]

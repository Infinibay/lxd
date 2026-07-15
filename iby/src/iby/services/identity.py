"""Identity test engines (OpenLDAP + Samba AD) for exercising the Identity feature.

Runs a throwaway directory server as a separate compose project (infinibay-identity)
attached to the dev-stack network, so the backend can point an IdentityProvider at
`openldap:389` / `samba-dc:389` and do test-bind → sync → login end to end. The
`config` verb prints the exact, paste-ready UI field values (incl. the OpenLDAP
filter overrides the AD-shaped defaults would otherwise miss).
"""

from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from rich.table import Table

from ..core.context import AppContext
from ..core.errors import IbyError
from ..runtime import detect

IDENTITY_PROJECT = "infinibay-identity"
DEV_NETWORK_DEFAULT = "infinibay-dev_default"

# Service + paste-ready IdentityProvider config per engine kind. Field names match
# backend CreateIdentityProviderInput; providerType is the UPPERCASE wire enum.
ENGINES: dict[str, dict] = {
    "ldap": {
        "service": "openldap",
        "label": "OpenLDAP",
        "config": {
            "name": "Test OpenLDAP",
            "providerType": "LDAP",
            "host": "openldap",
            "port": "636",
            "useTls": "true",
            "tlsInsecureSkipVerify": "true",
            "baseDn": "dc=infinibay,dc=local",
            "bindDn": "cn=admin,dc=infinibay,dc=local",
            "bindPassword": "admin",
            "userFilter": "(objectClass=inetOrgPerson)",
            "groupFilter": "(objectClass=groupOfNames)",
        },
        "users": [("alice", "Passw0rd!"), ("bob", "Passw0rd!")],
    },
    "ad": {
        "service": "samba-dc",
        "label": "Samba Active Directory",
        "config": {
            "name": "Test Active Directory",
            "providerType": "ACTIVE_DIRECTORY",
            "domain": "infinibay.lan",
            "host": "samba-dc",
            "port": "636",
            "useTls": "true",
            "tlsInsecureSkipVerify": "true",
            "baseDn": "DC=infinibay,DC=lan",
            "bindDn": "administrator@infinibay.lan",
            "bindPassword": "Passw0rd!Passw0rd!",
            "userFilter": "(objectClass=user)",
            "groupFilter": "(objectClass=group)",
        },
        "users": [("alice", "Passw0rd!"), ("bob", "Passw0rd!")],
    },
}


def _spec(kind: str) -> dict:
    if kind not in ENGINES:
        raise IbyError(f"unknown engine kind '{kind}' (use: ldap | ad)")
    return ENGINES[kind]


# ── assets ───────────────────────────────────────────────────────────────────
def _assets_src() -> Path:
    return Path(__file__).resolve().parents[1] / "data" / "identity"


def _assets_dir(ctx: AppContext) -> Path:
    """Materialise the packaged compose + seed assets under <project>/engines/identity.

    Kept on disk (not just in the wheel) so they are inspectable and editable, and
    so the compose file's relative volume paths (./ldap-seed) resolve.
    """
    dest = ctx.require_project_dir() / "engines" / "identity"
    if not (dest / "docker-compose.identity.yml").exists() and not ctx.dry_run:
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copytree(_assets_src(), dest, dirs_exist_ok=True)
        ctx.console.info(f"materialised identity engine assets → {dest}")
    return dest


# ── namespace + network ──────────────────────────────────────────────────────
def _network_name(ctx: AppContext) -> str:
    return os.environ.get("IDENTITY_NETWORK") or DEV_NETWORK_DEFAULT


def _network_exists(ctx: AppContext, net: str, *, sudo: bool) -> bool:
    names = ctx.runner.capture(["docker", "network", "ls", "--format", "{{.Name}}"], sudo=sudo).splitlines()
    return net in names


def _stack_running(ctx: AppContext, *, sudo: bool) -> bool:
    return bool(ctx.runner.capture(["docker", "ps", "--filter", "name=infinibay-dev", "--format", "{{.Names}}"], sudo=sudo).strip())


def _resolve_sudo(ctx: AppContext) -> bool:
    """The identity engine must share the backend's podman namespace.

    Deterministic override first: `IBY_ENGINE_SUDO=1|0` forces rootful/rootless (use it
    when the stack runs rootful — auto-detection needs a TTY for its `sudo docker ps`
    probe, which a backgrounded `up` can't provide, and a stale rootless network would
    otherwise misroute the engine away from a rootful backend).

    Otherwise: prefer the namespace where the stack is actually RUNNING; only then fall
    back to wherever the network merely exists. Rootless is probed first so a rootless
    host never sudos.
    """
    override = os.environ.get("IBY_ENGINE_SUDO")
    if override is not None:
        return override.strip().lower() in ("1", "true", "yes", "on")
    if ctx.dry_run:
        return False
    net = _network_name(ctx)
    if _stack_running(ctx, sudo=False):
        return False
    if detect.has("sudo") and _stack_running(ctx, sudo=True):
        return True
    if _network_exists(ctx, net, sudo=False):
        return False
    if detect.has("sudo") and _network_exists(ctx, net, sudo=True):
        return True
    raise IbyError(
        f"dev network '{net}' not found — run `iby up` first so the identity engine can attach to it.",
        hint="or set IDENTITY_NETWORK to your stack's network name",
    )


# ── compose driver for the identity project ──────────────────────────────────
def _compose(ctx: AppContext, kind: str, *args: str, sudo: bool, publish: bool = False,
             capture: bool = False, check: bool = True):
    assets = _assets_dir(ctx)
    provider = detect.resolve_compose(ctx.runner)
    files = ["-f", "docker-compose.identity.yml"]
    if publish:
        files += ["-f", "docker-compose.identity.ports.yml"]
    argv = [*provider, "-p", IDENTITY_PROJECT, *files, "--profile", kind, *args]
    return ctx.runner.run(argv, sudo=sudo, cwd=assets, capture=capture, check=check)


def _exec(ctx: AppContext, kind: str, service: str, command: list[str], *, sudo: bool,
          capture: bool = False, check: bool = True):
    return _compose(ctx, kind, "exec", "-T", service, *command, sudo=sudo, capture=capture, check=check)


def _ready(ctx: AppContext, kind: str, *, sudo: bool) -> bool:
    """A direct readiness bind probe (robust across podman, which may not surface
    container health status the way `docker inspect .State.Health` expects)."""
    if kind == "ldap":
        return _exec(
            ctx, kind, "openldap",
            ["ldapsearch", "-x", "-H", "ldap://localhost", "-D", "cn=admin,dc=infinibay,dc=local",
             "-w", "admin", "-b", "dc=infinibay,dc=local", "-s", "base"],
            sudo=sudo, capture=True, check=False,
        ).ok
    return _exec(ctx, kind, "samba-dc", ["samba-tool", "user", "list"], sudo=sudo, capture=True, check=False).ok


def _wait_healthy(ctx: AppContext, kind: str, service: str, *, sudo: bool, timeout: int = 180) -> bool:
    """Poll a direct bind probe until the directory answers (or timeout)."""
    if ctx.dry_run:
        return True
    ctx.console.info(f"waiting for {service} to become ready…")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _ready(ctx, kind, sudo=sudo):
            ctx.console.success(f"{service} is ready.")
            return True
        time.sleep(3)
    ctx.console.warn(
        f"{service} not ready within {timeout}s (continuing; try `iby engine {kind} seed` then `status`)."
    )
    return False


# ── verbs ────────────────────────────────────────────────────────────────────
def up(ctx: AppContext, kind: str, *, seed: bool = True, publish: bool = False) -> None:
    spec = _spec(kind)
    sudo = _resolve_sudo(ctx)
    _compose(ctx, kind, "up", "-d", sudo=sudo, publish=publish)
    if _wait_healthy(ctx, kind, spec["service"], sudo=sudo) and seed:
        _seed(ctx, kind, sudo=sudo, memberof=(kind == "ldap"))
    ctx.console.plain("")
    config(ctx, kind)


def down(ctx: AppContext, kind: str, *, volumes: bool = False) -> None:
    sudo = _resolve_sudo(ctx)
    args = ["down"]
    if volumes:
        args.append("-v")
    _compose(ctx, kind, *args, sudo=sudo, check=False)


def _seed(ctx: AppContext, kind: str, *, sudo: bool, memberof: bool) -> None:
    spec = _spec(kind)
    ctx.console.info(f"seeding {spec['label']} with alice + bob and two groups…")
    if kind == "ldap":
        _exec(
            ctx, kind, "openldap",
            ["ldapadd", "-c", "-x", "-D", "cn=admin,dc=infinibay,dc=local", "-w", "admin", "-f", "/seed/01-seed.ldif"],
            sudo=sudo, check=False,
        )
        if memberof:
            res = _exec(
                ctx, kind, "openldap",
                ["ldapmodify", "-Y", "EXTERNAL", "-H", "ldapi:///", "-f", "/seed/10-memberof.ldif"],
                sudo=sudo, check=False, capture=True,
            )
            if not res.ok:
                ctx.console.warn(
                    "memberOf overlay not applied (group→role mapping stays USER). "
                    "Non-fatal; see engines/identity/ldap-seed/10-memberof.ldif."
                )
    else:
        _exec(ctx, kind, "samba-dc", ["sh", "/seed/seed.sh"], sudo=sudo, check=False)


def seed(ctx: AppContext, kind: str, *, memberof: bool = False) -> None:
    _seed(ctx, kind, sudo=_resolve_sudo(ctx), memberof=memberof)


def status(ctx: AppContext, kind: str) -> None:
    spec = _spec(kind)
    sudo = _resolve_sudo(ctx)
    _compose(ctx, kind, "ps", sudo=sudo, check=False)
    if kind == "ldap":
        res = _exec(
            ctx, kind, "openldap",
            ["ldapsearch", "-x", "-H", "ldap://localhost", "-D", "cn=admin,dc=infinibay,dc=local",
             "-w", "admin", "-b", "dc=infinibay,dc=local", "-LLL", "(objectClass=inetOrgPerson)", "dn"],
            sudo=sudo, capture=True, check=False,
        )
        if res.ok:
            users = sum(1 for line in res.stdout.splitlines() if line.startswith("dn:"))
            ctx.console.success(f"LDAP bind OK — {users} user(s) under dc=infinibay,dc=local.")
        else:
            ctx.console.warn("LDAP bind probe failed — is the engine up? (`iby engine ldap up`)")
    else:
        res = _exec(ctx, kind, "samba-dc", ["samba-tool", "user", "list"], sudo=sudo, capture=True, check=False)
        if res.ok:
            n = len([u for u in res.stdout.splitlines() if u.strip()])
            ctx.console.success(f"AD reachable — {n} user(s) in the domain.")
            ctx.console.info(
                "In-guest domain-join additionally needs the guest's DNS pointed at the DC "
                "(department gateway 10.10.X.1) and `up --publish-ports`."
            )
        else:
            ctx.console.warn("AD probe failed — is the engine up? (`iby engine ad up`)")


def logs(ctx: AppContext, kind: str, *, follow: bool = True) -> None:
    spec = _spec(kind)
    sudo = _resolve_sudo(ctx)
    args = ["logs"]
    if follow:
        args.append("-f")
    _compose(ctx, kind, *args, spec["service"], sudo=sudo, check=False)


def config(ctx: AppContext, kind: str) -> None:
    spec = _spec(kind)
    cfg = spec["config"]
    table = Table(title=f"IdentityProvider — {spec['label']} (paste into the UI)", title_style="bold cyan")
    table.add_column("field", style="bold")
    table.add_column("value", style="green")
    for key, val in cfg.items():
        table.add_row(key, val)
    ctx.console.render(table)
    creds = ", ".join(f"{u} / {p}" for u, p in spec["users"])
    ctx.console.info(f"test users: {creds}")
    ctx.console.info("flow: paste → Test connection → Sync (creates the users) → log in as a user.")
    ctx.console.info(
        "note: useTls=true + tlsInsecureSkipVerify=true — the backend's ldapts client negotiates TLS on "
        "bind, so the directory is served over LDAPS (:636) with a self-signed cert (accepted in dev)."
    )
    if kind == "ldap":
        ctx.console.info(
            "note: the userFilter/groupFilter above OVERRIDE the AD-shaped defaults — without them "
            "sync silently returns 0 users."
        )


def ls(ctx: AppContext) -> None:
    sudo = _resolve_sudo(ctx)
    table = Table(title="identity engines", title_style="bold cyan")
    table.add_column("engine", style="bold")
    table.add_column("service")
    table.add_column("running")
    for kind, spec in ENGINES.items():
        cid = _compose(ctx, kind, "ps", "-q", spec["service"], sudo=sudo, capture=True, check=False).stdout.strip()
        running = "[green]yes[/]" if cid else "[dim]no[/]"
        table.add_row(kind, spec["service"], running)
    ctx.console.render(table)

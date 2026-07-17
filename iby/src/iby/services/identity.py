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
        # group DN → suggested role, for the group→role mapping the backend applies on
        # sync (needs the memberOf overlay, which `up`/`seed --memberof` enables).
        "groups": [
            ("cn=infinibay-admins,ou=groups,dc=infinibay,dc=local", "ADMIN"),
            ("cn=infinibay-users,ou=groups,dc=infinibay,dc=local", "USER"),
        ],
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
        # AD populates memberOf natively (no overlay needed).
        "groups": [
            ("CN=infinibay-admins,CN=Users,DC=infinibay,DC=lan", "ADMIN"),
            ("CN=infinibay-users,CN=Users,DC=infinibay,DC=lan", "USER"),
        ],
    },
}


def _spec(kind: str) -> dict:
    if kind not in ENGINES:
        raise IbyError(f"unknown engine kind '{kind}' (use: ldap | ad)")
    return ENGINES[kind]


# ── assets ───────────────────────────────────────────────────────────────────
def _assets_src() -> Path:
    return Path(__file__).resolve().parents[1] / "data" / "identity"


_assets_synced = False


def _assets_dir(ctx: AppContext) -> Path:
    """Materialise the packaged compose + seed assets under <project>/engines/identity.

    Refreshed from the package once per `iby` invocation, so upgrading iby drops
    updated seed scripts automatically. The tree is throwaway + gitignored — edit the
    packaged sources under iby/src/iby/data/identity, not this copy. Kept on disk so
    the compose file's relative volume mounts (./ldap-seed) resolve and the assets are
    inspectable.
    """
    global _assets_synced
    dest = ctx.require_project_dir() / "engines" / "identity"
    if not ctx.dry_run and not _assets_synced:
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copytree(_assets_src(), dest, dirs_exist_ok=True)
        _assets_synced = True
    return dest


# ── namespace + network ──────────────────────────────────────────────────────
def _network_name(ctx: AppContext) -> str:
    return os.environ.get("IDENTITY_NETWORK") or DEV_NETWORK_DEFAULT


def _network_exists(ctx: AppContext, net: str, *, sudo: bool) -> bool:
    names = ctx.runner.capture([detect.container_cli(), "network", "ls", "--format", "{{.Name}}"], sudo=sudo).splitlines()
    return net in names


def _stack_running(ctx: AppContext, *, sudo: bool) -> bool:
    return bool(ctx.runner.capture([detect.container_cli(), "ps", "--filter", "name=infinibay-dev", "--format", "{{.Names}}"], sudo=sudo).strip())


def _resolve_sudo(ctx: AppContext) -> bool:
    """Decide whether the engine runs rootful (sudo) so it shares the backend's
    podman namespace — deterministically and WITHOUT needing a TTY.

    `IBY_ENGINE_SUDO=1|0` forces it. Otherwise, mirror exactly how `iby up` routes
    the stack (see runtime.detect_runtime):

      1. If a rootless dev stack is actually RUNNING, colocate rootless (no sudo).
         Only a running backend counts — a leftover rootless network is ignored, so
         a dangling net can't misroute a rootful stack (the old auto-detect bug).
      2. Else derive from the runtime alone: only rootless podman on a KVM Linux host
         is routed through sudo (rootful podman), which is what `iby up` does. Plain
         docker (root daemon), running as root, or rootful podman already sit in the
         correct namespace → no sudo.

    Every branch is a plain capability probe (geteuid / `docker info` / /dev/kvm) — no
    `sudo` invocation — so detection works head-less. A backgrounded `up` used to fall
    through to a stale rootless network here; now it can't, which is why the manual
    `IBY_ENGINE_SUDO=1` workaround is no longer needed.
    """
    override = os.environ.get("IBY_ENGINE_SUDO")
    if override is not None:
        return override.strip().lower() in ("1", "true", "yes", "on")
    if ctx.dry_run:
        return False
    if _stack_running(ctx, sudo=False):
        return False
    if os.geteuid() == 0:
        return False
    if not detect.is_podman(ctx.runner) or not detect.is_rootless_podman(ctx.runner):
        return False  # docker (root daemon) or rootful podman: current namespace is correct
    return detect.kvm_available() and detect.has("sudo")


def _require_network(ctx: AppContext, *, sudo: bool) -> None:
    """Fail early with guidance if the target namespace has no dev network to attach to."""
    if ctx.dry_run:
        return
    net = _network_name(ctx)
    if not _network_exists(ctx, net, sudo=sudo):
        raise IbyError(
            f"dev network '{net}' not found in the {'rootful' if sudo else 'rootless'} podman "
            "namespace — run `iby up` first so the identity engine can attach to it.",
            hint="non-standard project name → set IDENTITY_NETWORK; wrong namespace → IBY_ENGINE_SUDO=1|0",
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
    if kind == "ad":
        ctx.console.warn(
            "the AD engine runs a PRIVILEGED Samba DC (its own DNS/Kerberos, host-level "
            "reach). On a shared rootful (KVM) host it can stress the podman runtime and "
            "wedge sibling containers' crun state. Prefer running it when the main stack "
            "isn't live; recover with `iby down` + `sudo podman pod rm -f pod_infinibay-dev`. "
            "The group→role flow is already covered by the lighter `ldap` engine."
        )
    sudo = _resolve_sudo(ctx)
    _require_network(ctx, sudo=sudo)
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
                ctx, kind, "openldap", ["sh", "/seed/10-memberof.sh"],
                sudo=sudo, check=False, capture=True,
            )
            if res.ok:
                ctx.console.success(
                    "memberOf overlay applied — alice ∈ infinibay-admins+users, bob ∈ infinibay-users. "
                    "Map infinibay-admins → ADMIN in the UI to make alice an admin on sync."
                )
            else:
                ctx.console.warn(
                    "memberOf overlay not applied (group→role mapping stays USER). Non-fatal; "
                    "inspect engines/identity/ldap-seed/10-memberof.sh."
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
    groups = spec.get("groups") or []
    if groups:
        gtable = Table(title="group → role mappings (add under the provider to elevate roles)",
                       title_style="bold cyan")
        gtable.add_column("group DN", style="bold")
        gtable.add_column("role", style="green")
        for dn, role in groups:
            gtable.add_row(dn, role)
        ctx.console.render(gtable)
        ctx.console.info(
            "these drive group→role elevation on sync (map infinibay-admins → ADMIN and alice syncs as ADMIN). "
            + ("LDAP needs the memberOf overlay — `up`/`seed --memberof` enables it."
               if kind == "ldap" else "AD reports memberOf natively.")
        )
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

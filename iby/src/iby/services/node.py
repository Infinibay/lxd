"""Compute-node path. Port of dev.sh cmd_join / cmd_node / detect_node_runtime / dc_node.

Onboards THIS host as a compute node of a remote master (SAS-verified enrollment over
.env.node), then manages the node-agent. Unlike the master path it pulls in no master
overlays, runs no setup TUI, and seeds no master identity. Read verbs (logs/status/
restart) talk to the engine DIRECTLY on the resolved container — podman-compose prints
nothing for them and crashes on an incomplete .env.node.
"""

from __future__ import annotations

import os
import platform
import re
import socket
import sys
from dataclasses import dataclass, field
from pathlib import Path

from ..core import dotenv
from ..core.context import AppContext
from ..core.errors import IbyError, MissingTool, RuntimeUnavailable
from ..runtime import detect, registries
from . import lan, repos, stack

NODE_ENV_FILE = ".env.node"
NODE_COMPOSE_FILE = "docker-compose.node.yml"
NODE_KVM_COMPOSE_FILE = "docker-compose.node.kvm.yml"


@dataclass
class NodeRuntime:
    ctx: AppContext
    project_dir: Path
    compose_cmd: list[str]
    engine_sudo: bool
    kvm_active: bool
    compose_files: list[str]
    env_forward: dict[str, str] = field(default_factory=dict)

    def dc_node(self, *args: str, check: bool = True, capture: bool = False):
        argv = [*self.compose_cmd, "--env-file", NODE_ENV_FILE]
        for f in self.compose_files:
            argv += ["-f", f]
        argv += list(args)
        return self.ctx.runner.run(
            argv, sudo=self.engine_sudo, env_forward=self.env_forward, cwd=self.project_dir,
            check=check, capture=capture,
        )


def _node_env_path(ctx: AppContext) -> Path:
    return ctx.require_project_dir() / NODE_ENV_FILE


def _detect_node_runtime(ctx: AppContext, *, starting: bool, node_kvm: str | None):
    """(kvm_active, engine_sudo, extra_files, env_forward). Node KVM is OPT-IN."""
    kvm = node_kvm or dotenv.get_value(_node_env_path(ctx), "NODE_KVM") or ""
    if kvm.lower() not in ("on", "1", "true"):
        ctx.console.info("node: heartbeat/enroll only (rootless). Pass --kvm so MIGRATED VMs can boot on this host.")
        return False, False, [], {}
    if not (platform.system() == "Linux" and Path("/dev/kvm").exists()):
        raise RuntimeUnavailable(
            "node --kvm needs /dev/kvm on this host (Linux + hardware virtualization). Omit --kvm to run heartbeat-only."
        )
    env_forward = {"INFINIZATION_DISABLE_SANDBOX": os.environ.get("INFINIZATION_DISABLE_SANDBOX", "1")}
    ctx.console.info("node: KVM ON — migrated VMs can boot here (/dev/kvm present).")
    engine_sudo = False
    if (
        platform.system() == "Linux"
        and detect.is_podman(ctx.runner)
        and os.geteuid() != 0
        and detect.is_rootless_podman(ctx.runner)
    ):
        if not detect.has("sudo"):
            raise RuntimeUnavailable(
                "rootless podman + node KVM needs rootful access but 'sudo' is missing.",
                hint="install sudo, or run as root",
            )
        engine_sudo = True
        ctx.console.warn(
            "node --kvm ⇒ rootful podman (sudo). Its volumes are a SEPARATE namespace from a rootless "
            "enrollment — if you first joined WITHOUT --kvm, down the node and re-join with --kvm. "
            "You may be prompted for your password."
        )
        if starting:
            registries.ensure_root_registries(ctx)
    if starting:
        stack.ensure_host_modules(ctx)
    return True, engine_sudo, [NODE_KVM_COMPOSE_FILE], env_forward


def prepare_node_env(ctx: AppContext, *, starting: bool, node_kvm: str | None = None) -> NodeRuntime:
    project = ctx.require_project_dir()
    if not (detect.has("docker") or detect.has("podman")):
        raise MissingTool(
            "no container engine found (need docker or podman)",
            hint=detect.install_hint(),
        )
    compose_cmd = detect.resolve_compose(ctx.runner)
    if detect.is_podman(ctx.runner):
        registries.ensure_podman_registries(ctx)
    kvm_active, engine_sudo, extra_files, env_forward = _detect_node_runtime(ctx, starting=starting, node_kvm=node_kvm)
    return NodeRuntime(
        ctx=ctx, project_dir=project, compose_cmd=compose_cmd, engine_sudo=engine_sudo,
        kvm_active=kvm_active, compose_files=[NODE_COMPOSE_FILE, *extra_files], env_forward=env_forward,
    )


# ── enrollment-volume helpers ─────────────────────────────────────────────────
def _node_base_mountpoint(ctx: AppContext, sudo: bool) -> str:
    names = ctx.runner.capture([detect.container_cli(), "volume", "ls", "--format", "{{.Name}}"], sudo=sudo).splitlines()
    vol = next((n for n in names if n.endswith("node_infinibay_base")), "")
    if not vol:
        return ""
    return ctx.runner.capture([detect.container_cli(), "volume", "inspect", vol, "--format", "{{.Mountpoint}}"], sudo=sudo)


def _node_wipe_enrollment(ctx: AppContext, mp: str, sudo: bool) -> None:
    certs = [f"{mp}/certs/node-cert.pem", f"{mp}/certs/node-key.pem",
             f"{mp}/certs/cluster-ca.pem", f"{mp}/certs/join-state.json"]
    ctx.runner.run(["rm", "-f", *certs], sudo=sudo, check=False)


def _node_default_token(ctx: AppContext) -> str:
    project = ctx.require_project_dir()
    return (
        dotenv.get_value(project / ".env.docker", "INFINIBAY_CLUSTER_TOKEN")
        or dotenv.get_value(project / ".env.docker.example", "INFINIBAY_CLUSTER_TOKEN")
        or ""
    )


def _node_agent_container(ctx: AppContext, sudo: bool) -> str:
    out = ctx.runner.capture(
        [detect.container_cli(), "ps", "-a", "--filter", "name=node-agent", "--format", "{{.Names}}"], sudo=sudo
    )
    lines = out.splitlines()
    return lines[0] if lines else ""


def _normalize_master_url(url: str) -> str:
    if not re.match(r"^https?://", url):
        url = "http://" + url
    scheme, rest = url.split("://", 1)
    if "/" in rest:
        hp, tail = rest.split("/", 1)
        path = "/" + tail
    else:
        hp, path = rest, ""
    if ":" not in hp:
        hp = f"{hp}:4000"
    return f"{scheme}://{hp}{path}"


def _repos_dir_value(ctx: AppContext) -> str:
    if ctx.repos_dir_opt:
        return str(ctx.repos_dir_opt)
    return os.environ.get("REPOS_DIR") or "./repos"


def _prompt(text: str) -> str:
    try:
        return input(f"\033[1;36m[iby]\033[0m {text}").strip()
    except (EOFError, KeyboardInterrupt):
        return ""


# ── join ──────────────────────────────────────────────────────────────────────
def join(
    ctx: AppContext,
    *,
    master_url: str = "",
    name: str = "",
    token: str = "",
    mtls: bool = True,
    master_cn: str = "",
    kvm: bool = False,
    reenroll: bool = False,
    no_start: bool = False,
) -> None:
    node_kvm = "on" if kvm else "off"
    rt = prepare_node_env(ctx, starting=True, node_kvm=node_kvm)
    sudo = rt.engine_sudo

    # ── existing enrollment? use vs re-enroll ──
    mp = _node_base_mountpoint(ctx, sudo)
    if mp and ctx.runner.succeeds(["test", "-f", f"{mp}/certs/node-cert.pem"], sudo=sudo):
        act = "u"
        if reenroll:
            act = "r"
        elif sys.stdin.isatty():
            ctx.console.warn(f"this node already has an enrollment cert (in volume: {mp}/certs/node-cert.pem).")
            ctx.console.info("  [u] use it — just (re)start the heartbeat        (= iby node up)")
            ctx.console.info("  [r] re-enroll — delete the cert + pair again     (new 6-digit code)")
            ctx.console.info("  [c] cancel")
            ans = _prompt("Choice [u/r/c] (default u): ").lower()
            if ans in ("r", "rejoin"):
                act = "r"
            elif ans == "c":
                ctx.console.info("cancelled — nothing changed.")
                return
        if act == "u":
            ctx.console.info("using the existing enrollment — (re)starting the heartbeat…")
            repos.clone_one(ctx, "backend")
            repos.clone_one(ctx, "infinization")
            rt.dc_node("up", "-d", "--build", "node-agent")
            ctx.console.info("node heartbeating with its existing cert. Re-pair later with: iby node join <master> --reenroll")
            return
        ctx.console.info("re-enrolling — removing the old cert + join state so pairing starts fresh…")
        _node_wipe_enrollment(ctx, mp, sudo)

    ctx.console.info("onboarding THIS host as a compute node — cloning backend + infinization…")
    repos.clone_one(ctx, "backend")
    repos.clone_one(ctx, "infinization")

    # ── master URL (required) ──
    if not master_url and sys.stdin.isatty():
        master_url = _prompt("Master IP or URL (e.g. 192.168.1.50 or http://192.168.1.50:4000): ")
    if not master_url:
        raise IbyError(
            "the master URL is required: iby node join http://<master-ip>:4000  "
            "(find the IP on the master with: hostname -I)"
        )
    master_url = _normalize_master_url(master_url)
    ctx.console.info(f"master: {master_url}")

    if not name:
        name = socket.gethostname() or "node"

    # ── token ──
    if not token:
        default_tok = _node_default_token(ctx)
        if sys.stdin.isatty():
            if default_tok:
                token = _prompt(f"Cluster token [Enter = use {default_tok} from .env.docker]: ") or default_tok
            else:
                token = _prompt("Paste the master's cluster token: ")
        else:
            token = default_tok
    if not token:
        raise IbyError("a cluster token is required (get it on the master: grep INFINIBAY_CLUSTER_TOKEN .env.docker)")

    # ── mTLS derivations ──
    mtls_flag = 0
    master_cluster_url = ""
    node_address = lan.detect_host_ip(ctx)
    if mtls:
        mtls_flag = 1
        master_cn = master_cn or "master"
        mh = master_url.split("://", 1)[1].split("/", 1)[0].split(":")[0]
        port = os.environ.get("INFINIBAY_CLUSTER_PORT", "4433")
        master_cluster_url = f"https://{mh}:{port}"
        ctx.console.warn(
            "heartbeat in full mTLS (default) — the MASTER must run with INFINIBAY_CLUSTER_MTLS=1 (its :4433 "
            f"ops server) and its node name must be '{master_cn}' (override with --master-cn). If the master is "
            "still token-mode, re-run with --no-mtls."
        )

    # ── validate everything that lands in .env.node ──
    if not re.match(r"^https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+$", master_url):
        raise IbyError(f"master URL has unexpected characters: {master_url}")
    if not re.match(r"^[A-Za-z0-9._+=/:-]+$", token):
        raise IbyError("token has characters outside [A-Za-z0-9._+=/:-]")
    if not re.match(r"^[A-Za-z0-9._-]+$", name):
        raise IbyError(f"node name must match [A-Za-z0-9._-]: {name}")

    # ── write .env.node ──
    lines = [
        "# Generated by iby node join — compute-node runtime config. DO NOT COMMIT.",
        f"REPOS_DIR={_repos_dir_value(ctx)}",
        f"PORT_BIND={os.environ.get('PORT_BIND', '0.0.0.0')}",
        f"MASTER_URL={master_url}",
        f"INFINIBAY_NODE_NAME={name}",
        f"INFINIBAY_CLUSTER_TOKEN={token}",
        f"INFINIBAY_CLUSTER_MTLS={mtls_flag}",
        f"MASTER_CLUSTER_URL={master_cluster_url}",
        f"INFINIBAY_MASTER_CN={master_cn}",
        f"NODE_ADDRESS={node_address}",
        f"NODE_KVM={node_kvm}",
    ]
    if ctx.dry_run:
        ctx.console.info(f"dry-run: would write {NODE_ENV_FILE}")
    else:
        _node_env_path(ctx).write_text("\n".join(lines) + "\n")
        ctx.console.info(f"wrote {NODE_ENV_FILE}")

    # ── enrollment (interactive — prints the SAS pairing code) ──
    ctx.console.plain("")
    ctx.console.info(f"=== Joining cluster as node '{name}' ===")
    ctx.console.info(f"  Master:    {master_url}")
    ctx.console.info(f"  Node name: {name}")
    ctx.console.info(f"  Heartbeat: {'mTLS' if mtls_flag else 'token mode'}")
    ctx.console.warn(
        "A 6-digit PAIRING CODE prints below. Compare it with the code shown for this node in the master's "
        "Infrastructure UI, then APPROVE it there. If the codes differ, do NOT approve."
    )
    ctx.console.plain("")
    if not rt.dc_node(
        "run", "--rm", "node-agent",
        "node", "-r", "ts-node/register", "-r", "tsconfig-paths/register", "agent/join.ts",
        check=False,
    ).ok:
        raise IbyError(
            "enrollment failed. Check the master URL/token, that the master is reachable, and that it has "
            "INFINIBAY_CLUSTER_TOKEN set."
        )

    if no_start:
        ctx.console.info("enrollment done (--no-start). Start the heartbeat later with: iby node up")
        return
    ctx.console.info("approved — starting the heartbeat agent (first start builds infinization; slow, one-time)…")
    rt.dc_node("up", "-d", "--build", "node-agent")
    ctx.console.plain("")
    ctx.console.success(f"node '{name}' is enrolled and heartbeating → it should appear ONLINE in the master UI.")
    ctx.console.info("  logs: iby node logs   status: iby node status   stop: iby node down")
    if not mtls_flag:
        ctx.console.info("  (token mode via --no-mtls; cross-node VM migration needs mTLS — re-run without --no-mtls)")


# ── node lifecycle ─────────────────────────────────────────────────────────────
def node_cmd(ctx: AppContext, sub: str = "status", *, kvm: bool = False, rest: list[str] | None = None) -> None:
    rest = rest or []
    env_path = _node_env_path(ctx)
    if not env_path.exists():
        raise IbyError(f"no {NODE_ENV_FILE} — run `iby node join` first.")
    node_kvm = None
    if kvm:  # persist an explicit --kvm so later `node up` keeps the overlay
        node_kvm = "on"
        if not ctx.dry_run:
            dotenv.upsert(env_path, "NODE_KVM", "on")
    starting = sub in ("up", "restart")
    rt = prepare_node_env(ctx, starting=starting, node_kvm=node_kvm)
    sudo = rt.engine_sudo
    cid = _node_agent_container(ctx, sudo)
    ns = "rootful" if sudo else "rootless"
    hint = "start it with: iby node up" + (" --kvm" if rt.kvm_active else "")

    if sub == "up":
        rt.dc_node("up", "-d", "--build", "node-agent")
    elif sub in ("down", "stop"):
        rt.dc_node("down", *rest, check=False)
    elif sub == "restart":
        if not cid:
            raise IbyError(f"no node-agent container in the {ns} engine namespace — {hint}")
        ctx.console.info(f"restarting {cid}…")
        ctx.runner.run([detect.container_cli(), "restart", cid], sudo=sudo)
        ctx.runner.run([detect.container_cli(), "ps", "--filter", "name=node-agent"], sudo=sudo, check=False)
    elif sub == "logs":
        if not cid:
            raise IbyError(f"no node-agent container in the {ns} engine namespace — {hint}")
        ctx.console.info(f"streaming logs for {cid} (Ctrl-C to stop)…")
        ctx.runner.run([detect.container_cli(), "logs", "-f", *rest, cid], sudo=sudo, check=False)
    elif sub in ("status", "ps"):
        if cid:
            ctx.runner.run([detect.container_cli(), "ps", "-a", "--filter", "name=node-agent"], sudo=sudo, check=False)
        else:
            ctx.console.warn(f"no node-agent container in the {ns} engine namespace.")
            ctx.console.info(hint)
    else:
        raise IbyError(f"unknown node subcommand '{sub}'. Try: up | down | logs | status | restart")

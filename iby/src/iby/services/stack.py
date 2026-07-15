"""Dev-stack orchestration. Port of dev.sh ensure_env + the up/down/… dispatch.

`prepare_stack` reproduces dev.sh `ensure_env`: resolve the provider, seed the env
file + master identity, run the first-run TUI, assemble the compose overlays in the
exact override order (base → external-db → kvm → cluster), compute LAN access, and
return a ready-to-run StackRuntime. The command functions are thin wrappers over it.
"""

from __future__ import annotations

import os
import platform
import shlex
from pathlib import Path

from ..core import dotenv
from ..core.context import AppContext
from ..core.errors import IbyError, MissingTool
from ..models.enums import InfiniserviceMode
from ..runtime import detect, modules, registries
from ..runtime.compose import StackRuntime
from ..runtime.runtime import detect_runtime
from . import infiniservice, lan, repos, wizard


# ── env seeding (dev.sh ensure_master_env) ───────────────────────────────────
def _ensure_master_env(ctx: AppContext) -> None:
    p = ctx.env_path
    dotenv.ensure_key(p, "INFINIBAY_NODE_NAME", "master", "multi-node: stable identity of this master node")
    dotenv.ensure_key(p, "INFINIBAY_NODE_ROLE", "master", "multi-node: this dev host is the cluster master")
    dotenv.ensure_key(
        p, "INFINIBAY_CLUSTER_TOKEN", "dev-insecure-cluster-token",
        "multi-node: cluster bootstrap secret (DEV ONLY — use openssl rand -hex 32 for real multi-host)",
    )
    dotenv.ensure_key(
        p, "COMPOSE_PROFILES", "managed-db",
        "compose profiles active (managed-db → run the bundled postgres; the TUI clears this for an external DB)",
    )
    dotenv.ensure_key(
        p, "PORT_BIND", "0.0.0.0",
        "host interface published ports bind to (127.0.0.1 = loopback-only, or a LAN IP = pin the NIC)",
    )


def _require_docker(ctx: AppContext) -> None:
    if not detect.has("docker"):
        raise MissingTool("missing required tool: docker", hint="install docker, or podman (podman-docker)")


def prepare_stack(
    ctx: AppContext,
    *,
    want_kvm: bool | None = None,
    want_cluster: bool = False,
    want_mtls: bool | None = None,
    want_reconfigure: bool = False,
    sandbox: bool | None = None,
) -> StackRuntime:
    """Resolve everything needed to drive compose. Faithful to dev.sh ensure_env."""
    project = ctx.require_project_dir()
    _require_docker(ctx)
    compose_cmd = detect.resolve_compose(ctx.runner)
    ctx.console.info(f"compose provider: {' '.join(compose_cmd)}")
    if detect.is_podman(ctx.runner):
        registries.ensure_podman_registries(ctx)

    env_path = ctx.env_path
    if not env_path.exists() and not ctx.dry_run:
        example = project / f"{ctx.env_file_name}.example"
        ctx.console.info(f"creating {ctx.env_file_name} from {example.name} (edit it to change ports/creds)")
        env_path.write_text(example.read_text())

    # Env-file mutations are gated on --dry-run so a preview never writes.
    if not ctx.dry_run:
        _ensure_master_env(ctx)
        if want_mtls is not None:
            val = "1" if want_mtls else "0"
            dotenv.upsert(env_path, "INFINIBAY_CLUSTER_MTLS", val)
            ctx.console.info(f"cluster mTLS persisted → INFINIBAY_CLUSTER_MTLS={val} ({ctx.env_file_name})")
        if wizard.setup_needed(ctx) or want_reconfigure:
            wizard.run_setup_tui(ctx, reconfigure=want_reconfigure)

    file_env = dotenv.read_values(env_path)
    # dev.sh `set -a; . file`: the sourced file overrides the process env.
    merged_env = {**os.environ, **file_env}

    # ── compose overlays, in override order ──
    compose_files = ["docker-compose.yml"]
    if file_env.get("DATABASE_URL"):
        compose_files.append("docker-compose.external-db.yml")
        ctx.console.info("external database configured — bundled postgres disabled")
    decision = detect_runtime(ctx, want_kvm=want_kvm, merged_env=merged_env)
    compose_files += decision.extra_files
    if want_cluster:
        compose_files.append("docker-compose.cluster.yml")
        ctx.console.info("cluster emulation ON — adds compute-node agents (node-1, node-2)")

    overrides = lan.configure_lan_access(ctx, merged_env)
    profiles = [p for p in (file_env.get("COMPOSE_PROFILES") or "").split(",") if p]

    env_forward: dict[str, str] = {}
    if sandbox is not None:
        env_forward["INFINIZATION_DISABLE_SANDBOX"] = "0" if sandbox else "1"
    # Effective mTLS: this run's --mtls/--no-mtls wins; else the persisted file value.
    if want_mtls is not None:
        eff_mtls = "1" if want_mtls else "0"
    else:
        eff_mtls = dotenv.get_value(env_path, "INFINIBAY_CLUSTER_MTLS")
    if eff_mtls:
        env_forward["INFINIBAY_CLUSTER_MTLS"] = eff_mtls

    return StackRuntime(
        ctx=ctx,
        project_dir=project,
        compose_cmd=compose_cmd,
        env_file_name=ctx.env_file_name,
        compose_files=compose_files,
        engine_sudo=decision.engine_sudo,
        kvm_active=decision.kvm_active,
        profiles=profiles,
        env_overrides=overrides,
        env_forward=env_forward,
        env=merged_env,
    )


# ── host kernel modules (dev.sh ensure_host_modules) ─────────────────────────
def ensure_host_modules(ctx: AppContext) -> None:
    if platform.system() != "Linux":
        return
    sudo = os.geteuid() != 0
    missing = modules.missing_modules()
    if missing:
        ctx.console.info("loading host kernel modules for VMs: " + " ".join(missing))
        for m in missing:
            if not ctx.runner.run(["modprobe", m], sudo=sudo, check=False).ok:
                ctx.console.warn(f"could not modprobe {m} (continuing)")
    persist = "/etc/modules-load.d/infinibay-dev.conf"
    if not Path(persist).exists():
        mods = modules.required_vm_modules()
        script = f'printf "%s\\n" {" ".join(shlex.quote(m) for m in mods)} > {shlex.quote(persist)}'
        if ctx.runner.run(["sh", "-c", script], sudo=sudo, check=False).ok:
            ctx.console.info(f"persisted modules → {persist} (auto-load on boot)")
        else:
            ctx.console.warn(f"could not persist modules to {persist} (non-fatal)")


def _handle_infiniservice(ctx: AppContext, rt: StackRuntime, mode: InfiniserviceMode) -> None:
    if mode == InfiniserviceMode.rebuild:
        ctx.console.info("rebuilding the infiniservice guest agent (--infiniservice rebuild)…")
        infiniservice.build(ctx, rt)
    elif mode == InfiniserviceMode.skip:
        ctx.console.warn("--infiniservice skip: guests will 404 the agent until you run `iby infiniservice build`.")
    elif not rt.kvm_active:
        return  # control-plane-only: no VMs to serve the agent to
    elif ctx.dry_run:
        ctx.console.info("dry-run: would build the infiniservice agent if missing (skipped the volume probe).")
    elif infiniservice.built(ctx, rt):
        ctx.console.info("infiniservice guest agent already compiled — skipping build.")
    else:
        ctx.console.warn("infiniservice guest agent not compiled yet — building it now (slow, one-time).")
        infiniservice.build(ctx, rt)


def _print_urls(ctx: AppContext, rt: StackRuntime) -> None:
    bp = rt.env.get("BACKEND_PORT", "4000")
    fp = rt.env.get("FRONTEND_PORT", "3000")
    ctx.console.info("building images + starting stack…")
    ctx.console.info("first run installs all deps inside the containers — give it several minutes.")
    ctx.console.info(f"  backend  → http://localhost:{bp}/graphql")
    ctx.console.info(f"  frontend → http://localhost:{fp}")
    host_ip = rt.env_overrides.get("HOST_IP")
    if host_ip:
        ctx.console.info("  reachable from other devices on the LAN:")
        ctx.console.info(f"    frontend → http://{host_ip}:{fp}")
        ctx.console.info(f"    backend  → http://{host_ip}:{bp}/graphql")


# ── commands ─────────────────────────────────────────────────────────────────
def up(
    ctx: AppContext,
    *,
    want_kvm: bool | None,
    want_cluster: bool,
    want_mtls: bool | None,
    want_reconfigure: bool,
    sandbox: bool | None,
    infiniservice_mode: InfiniserviceMode,
    build: bool,
    detach: bool,
    passthrough: list[str],
) -> None:
    rt = prepare_stack(
        ctx,
        want_kvm=want_kvm,
        want_cluster=want_cluster,
        want_mtls=want_mtls,
        want_reconfigure=want_reconfigure,
        sandbox=sandbox,
    )
    # mtls ⊕ cluster guard — evaluated AFTER prepare so it sees the EFFECTIVE mtls
    # value (this run's flag OR a value persisted in the env file).
    if rt.env_forward.get("INFINIBAY_CLUSTER_MTLS") == "1" and want_cluster:
        raise IbyError(
            "--mtls and --cluster are mutually exclusive: under cluster mTLS the token heartbeat path "
            "returns 421, so the emulated node-1/node-2 cannot register. Use --cluster for same-host "
            "token emulation, OR --mtls for real remote mTLS nodes (iby node join, mTLS by default)."
        )
    repos.clone_all(ctx)
    if rt.kvm_active:
        ensure_host_modules(ctx)
    _handle_infiniservice(ctx, rt, infiniservice_mode)
    _print_urls(ctx, rt)
    args = ["up"]
    if build:
        args.append("--build")
    if detach:
        args.append("-d")
    args += passthrough
    rt.compose(*args)


def down(ctx: AppContext, extra: list[str]) -> None:
    prepare_stack(ctx).compose("down", *extra)


def logs(ctx: AppContext, services: list[str]) -> None:
    prepare_stack(ctx).compose("logs", "-f", *services)


def status(ctx: AppContext, extra: list[str]) -> None:
    prepare_stack(ctx).compose("ps", *extra)


def restart(ctx: AppContext, services: list[str]) -> None:
    prepare_stack(ctx).compose("restart", *services)


def exec_service(ctx: AppContext, service: str, command: list[str]) -> None:
    prepare_stack(ctx).compose("exec", service, *command)


def clean(ctx: AppContext) -> None:
    rt = prepare_stack(ctx)
    ctx.console.warn("removing volumes (db, node_modules, caches) and built images…")
    rt.compose("--profile", "builders", "down", "-v", "--rmi", "local", check=False)


def build_infiniservice(ctx: AppContext) -> None:
    rt = prepare_stack(ctx)
    infiniservice.build(ctx, rt)


def pull(ctx: AppContext) -> None:
    """Fast-forward the app repos. NEVER runs ensure_env / the setup TUI (dev.sh pull)."""
    env_path = ctx.env_path
    if env_path.exists():
        fe = dotenv.read_values(env_path)
        if fe.get("REPOS_DIR"):
            ctx.repos_dir_opt = Path(fe["REPOS_DIR"])
        if fe.get("REPO_REF"):
            ctx.repo_ref = fe["REPO_REF"]
    repos.pull_all(ctx)

"""LAN reachability. Port of dev.sh detect_host_ip / detect_public_ip / configure_lan_access.

Computes the env overrides that make the stack reachable from other devices:
the browser bundle's NEXT_PUBLIC_* target and the backend CORS allow-list. Returns
a plain dict of overrides — the caller injects them into the compose child env.
"""

from __future__ import annotations

from ..core.context import AppContext


def detect_host_ip(ctx: AppContext) -> str:
    """Primary LAN IPv4 (source addr toward the internet). ip → hostname -I."""
    out = ctx.runner.capture(["ip", "-4", "route", "get", "1.1.1.1"])
    if out:
        toks = out.split()
        for i, tok in enumerate(toks):
            if tok == "src" and i + 1 < len(toks):
                return toks[i + 1]
    return (ctx.runner.capture(["hostname", "-I"]).split() or [""])[0]


def detect_public_ip(ctx: AppContext) -> str:
    """Egress IPv4 via a single short external call (only when PUBLIC_IP=auto)."""
    for url in ("https://api.ipify.org", "https://ifconfig.me"):
        ip = ctx.runner.capture(["curl", "-fsS", "--max-time", "4", url])
        if ip:
            return ip
    return ""


def _append_origin(origins: list[str], origin: str) -> None:
    if origin and origin not in origins:
        origins.append(origin)


def configure_lan_access(ctx: AppContext, env: dict[str, str]) -> dict[str, str]:
    """Return env overrides for LAN access (NEXT_PUBLIC_*, APP_HOST, CORS list)."""
    overrides: dict[str, str] = {}
    fp = env.get("FRONTEND_PORT", "3000")
    bp = env.get("BACKEND_PORT", "4000")

    # ── LAN IP (auto, unless pinned or opted out with HOST_IP=localhost) ──
    host_ip = env.get("HOST_IP") or detect_host_ip(ctx)
    if host_ip in ("localhost", "127.0.0.1"):
        host_ip = ""
    if host_ip:
        overrides["HOST_IP"] = host_ip
    else:
        ctx.console.warn("no LAN IP detected — remote access limited (set HOST_IP=... to force)")

    # ── public IP (opt-in) ──
    public_ip = env.get("PUBLIC_IP", "")
    if public_ip == "auto":
        public_ip = detect_public_ip(ctx)
        if public_ip:
            ctx.console.info(f"detected public IP: {public_ip}")
        else:
            ctx.console.warn("PUBLIC_IP=auto but detection failed (skipping public origin)")

    # ── what the browser bundle talks to (single host) ──
    advertise = env.get("ADVERTISE_HOST") or host_ip
    if advertise:
        localish = ("", None)
        npb = env.get("NEXT_PUBLIC_BACKEND_HOST", "")
        if npb == "" or npb.startswith(("http://localhost:", "http://127.0.0.1:")):
            overrides["NEXT_PUBLIC_BACKEND_HOST"] = f"http://{advertise}:{bp}"
        npg = env.get("NEXT_PUBLIC_GRAPHQL_API_URL", "")
        if npg == "" or npg.startswith(("http://localhost:", "http://127.0.0.1:")):
            overrides["NEXT_PUBLIC_GRAPHQL_API_URL"] = f"http://{advertise}:{bp}/graphql"
        if env.get("APP_HOST", "") in ("", "localhost", "127.0.0.1"):
            overrides["APP_HOST"] = advertise
        if env.get("GRAPHIC_HOST", "") in ("", "localhost", "127.0.0.1"):
            overrides["GRAPHIC_HOST"] = advertise

    # ── CORS allow-list (exact match) ──
    base = env.get("ALLOWED_ORIGINS") or f"http://localhost:{fp},http://127.0.0.1:{fp}"
    origins = [o for o in base.split(",") if o]
    for h in ("localhost", "127.0.0.1", host_ip, public_ip):
        if h:
            _append_origin(origins, f"http://{h}:{fp}")
    for extra in (env.get("EXTRA_ORIGINS") or "").split(","):
        extra = extra.strip()
        if extra:
            _append_origin(origins, extra)
    joined = ",".join(origins)
    overrides["ALLOWED_ORIGINS"] = joined
    overrides["FRONTEND_URL"] = joined  # socket.io reads ALLOWED_ORIGINS; keep FRONTEND_URL aligned
    return overrides

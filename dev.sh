#!/usr/bin/env bash
# Infinibay — one-command Docker dev environment.
#
#   ./dev.sh up            clone/refresh repos, then start the stack (live logs)
#   ./dev.sh up -d         same, detached
#
# KVM is AUTO-DETECTED: on Linux with /dev/kvm the full hypervisor override is
# applied automatically (VMs enabled); on macOS / hosts without /dev/kvm it runs
# control-plane-only. No flag needed. Force it either way with:
#   ./dev.sh up --kvm      force the hypervisor override ON
#   ./dev.sh up --no-kvm   force control-plane-only (skip the override)
#   KVM=on|off ./dev.sh up same, via env (also settable in .env.docker)
#
# QEMU SECCOMP SANDBOX defaults OFF so VMs boot on this rootless-podman substrate
# (the sandbox otherwise kills QEMU's device-init syscall with SIGSYS). Opt in:
#   ./dev.sh up --sandbox     run QEMU with its seccomp sandbox ON (secure; may
#                             SIGSYS on rootless podman)
#   ./dev.sh up --no-sandbox  explicit default — sandbox OFF (VMs boot)
#   INFINIZATION_DISABLE_SANDBOX=0|1 ./dev.sh up   same, via env (0 = sandbox on)
#
# MULTI-NODE: this stack always comes up as the cluster MASTER (a dev cluster
# token + stable node name are auto-seeded into .env.docker on first `up`). To also
# emulate compute nodes on this one host:
#   ./dev.sh up --cluster     add node-1/node-2 compute-agent heartbeats
# To onboard a REAL second physical host as a compute node, run ON THAT HOST:
#   ./dev.sh join http://<master-ip>:4000     pair (SAS) + start the node agent
#   ./dev.sh join                             same, but prompts for the master IP
#   ./dev.sh node logs|status|down|up         manage the node agent afterwards
# (You supply the master URL explicitly — find its IP on the master with
#  `hostname -I`. The token defaults to the one in .env.docker; get the master's
#  with `grep INFINIBAY_CLUSTER_TOKEN .env.docker`. `./dev.sh join --help` for
#  options. The LXD self-host path has its own `./run.sh join`.)
#
# LAN ACCESS is automatic: `up` detects this host's LAN IP and advertises it so
# the UI/API are reachable from other devices (the published ports already bind
# 0.0.0.0). It points the browser bundle at that IP and adds it to the backend
# CORS allow-list; localhost keeps working too. Override or disable with:
#   HOST_IP=192.168.1.50 ./dev.sh up   force a specific advertised IP
#   HOST_IP=localhost   ./dev.sh up    stay localhost-only (no LAN access)
#   ./dev.sh down          stop the stack
#   ./dev.sh down -v       stop and DELETE all volumes (node_modules, db, …)
#   ./dev.sh logs [svc]    follow logs (optionally one service)
#   ./dev.sh pull          fast-forward every repo to its latest origin/<ref>
#   ./dev.sh restart [svc] restart the stack (or one service)
#   ./dev.sh status        compose ps
#   ./dev.sh build-infiniservice   cross-compile the Rust guest agent (also built
#                                  automatically by `up` on a KVM host when missing;
#                                  bypass/force with up --skip-infiniservice /
#                                  --rebuild-infiniservice)
#   ./dev.sh clean         down -v + remove built images
#
# Source repos are cloned into $REPOS_DIR (default ./repos) and bind-mounted.
# Edit code there → it reloads live. `up` never clobbers your local edits;
# use `pull` to deliberately advance to the latest main.
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env.docker"
ENV_EXAMPLE=".env.docker.example"
COMPOSE_FILES=(-f docker-compose.yml)
COMPOSE_CMD=() # the resolved Compose v2 provider (podman-compose / docker compose)
ENGINE_SUDO="" # set to "sudo" when rootless podman needs rootful access for VMs
KVM_ACTIVE=0   # set to 1 by detect_runtime when the hypervisor override is enabled

REPOS=(backend frontend infinization infiniservice)
GH_ORG="Infinibay"
NODE_ENV_FILE=".env.node"                # ./dev.sh join writes the compute-node runtime config here
NODE_COMPOSE_FILE="docker-compose.node.yml"
NODE_KVM_COMPOSE_FILE="docker-compose.node.kvm.yml"  # opt-in KVM overlay so migrated VMs can boot on the node
NODE_COMPOSE_FILES=(-f "$NODE_COMPOSE_FILE")          # built up by prepare_node_env (+ KVM overlay when --kvm)

c() { printf '\033[1;36m[dev]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dev]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dev]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Podman (incl. the podman-docker CLI shim) does NOT default unqualified image
# names to docker.io the way Docker does, so `postgres:16-bookworm`,
# `node:20-bookworm`, etc. fail with:
#   short-name "…" did not resolve to an alias and no unqualified-search
#   registries are defined
# Give rootless podman a user-level registries.conf that resolves bare names to
# docker.io, exactly like Docker. No-op under real Docker, and we never touch
# the system /etc config (no root needed).
ensure_podman_registries() {
  docker --version 2>&1 | grep -qi podman || return 0
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/containers/registries.conf"
  if [ -f "$conf" ] && grep -q "unqualified-search-registries" "$conf"; then
    return 0
  fi
  c "podman detected → enabling docker.io short-name resolution ($conf)"
  mkdir -p "$(dirname "$conf")"
  if [ -f "$conf" ]; then
    # prepend so the top-level key never lands inside an existing [[registry]] table
    local tmp; tmp="$(mktemp)"
    printf 'unqualified-search-registries = ["docker.io"]\n\n' >"$tmp"
    cat "$conf" >>"$tmp"
    mv "$tmp" "$conf"
  else
    printf 'unqualified-search-registries = ["docker.io"]\n' >"$conf"
  fi
}

# Rootful podman reads root's config, not the per-user file ensure_podman_registries
# writes. A drop-in keeps docker.io short-name resolution working there too without
# editing the distro's main /etc/containers/registries.conf.
ensure_root_registries() {
  local dropin=/etc/containers/registries.conf.d/00-infinibay-dockerio.conf
  sudo test -f "$dropin" 2>/dev/null && return 0
  c "enabling docker.io short-name resolution for rootful podman ($dropin)"
  sudo mkdir -p /etc/containers/registries.conf.d
  printf 'unqualified-search-registries = ["docker.io"]\n' | sudo tee "$dropin" >/dev/null
}

# VM networking needs a few HOST kernel modules: br_netfilter (so bridge traffic
# hits iptables → DHCP works), tun (TAP devices), vhost_net + kvm (the hypervisor).
# A container can't modprobe the host kernel, so we load them here on the host;
# the backend then sees them via the shared /proc/modules and skips its own
# modprobe. Idempotent, and persisted to /etc/modules-load.d so they survive reboot.
ensure_host_modules() {
  [ "$(uname -s)" = "Linux" ] || return 0
  local s=""; [ "$(id -u)" -ne 0 ] && s="sudo"
  local kvm_mod=kvm_amd
  grep -q GenuineIntel /proc/cpuinfo 2>/dev/null && kvm_mod=kvm_intel
  local mods="br_netfilter tun vhost_net kvm $kvm_mod"
  c "ensuring host kernel modules for VMs: $mods"
  local m
  for m in $mods; do
    $s modprobe "$m" 2>/dev/null || warn "could not modprobe $m (continuing)"
  done
  local persist=/etc/modules-load.d/infinibay-dev.conf
  if ! $s test -f "$persist" 2>/dev/null; then
    printf '%s\n' $mods | $s tee "$persist" >/dev/null 2>&1 \
      && c "persisted modules → $persist (auto-load on boot)" \
      || warn "could not persist modules to $persist (non-fatal)"
  fi
}

# Auto-select control-plane-only vs full hypervisor (KVM) mode, and decide whether
# engine calls must be rootful. KVM=on|off forces it; KVM=auto (default) enables
# the hypervisor override on Linux when /dev/kvm exists and disables it everywhere
# else (e.g. macOS / Docker Desktop). Launching VMs needs real host privilege —
# bridges, nftables, TAP devices: Docker's daemon already runs as root, but
# ROOTLESS podman cannot, so we route the engine through sudo to get rootful podman.
# Cloning/git stay as the normal user (never sudo) so ./repos keeps your ownership.
detect_runtime() {
  local want_kvm=0
  case "${KVM:-auto}" in
    on|1|true)   want_kvm=1 ;;
    off|0|false) want_kvm=0 ;;
    *) { [ "$(uname -s)" = "Linux" ] && [ -e /dev/kvm ]; } && want_kvm=1 ;;
  esac
  if [ "$want_kvm" != 1 ]; then
    c "control-plane-only mode (no /dev/kvm, or KVM=off) — UI/API/DB, no VMs"
    return 0
  fi
  COMPOSE_FILES+=(-f docker-compose.kvm.yml)
  KVM_ACTIVE=1
  c "full hypervisor mode — /dev/kvm present, VMs enabled"
  # Rootful only matters for podman; Docker's daemon is already root.
  if docker --version 2>&1 | grep -qi podman \
     && [ "$(id -u)" -ne 0 ] \
     && docker info 2>/dev/null | grep -q "rootless: true"; then
    command -v sudo >/dev/null 2>&1 \
      || die "rootless podman + KVM needs rootful access but 'sudo' is missing. Install sudo, or run this as root."
    ENGINE_SUDO="sudo"
    warn "rootless podman can't manage host bridges/nft/TAP — routing the engine through sudo (rootful podman). You may be prompted for your password."
    ensure_root_registries
  fi
}

# Best-effort discovery of this host's primary LAN IPv4 (the source address the
# kernel would use to reach the internet — i.e. the address other devices on the
# LAN can reach us at). Linux `ip`, then macOS `ipconfig`, then `hostname -I`.
# Prints nothing if it can't find one.
detect_host_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [ -z "$ip" ] && command -v ipconfig >/dev/null 2>&1; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

# Optional public/egress IPv4. OFF by default; only runs when PUBLIC_IP=auto, and
# then makes a single short external HTTP call. A literal PUBLIC_IP=1.2.3.4 is used
# verbatim with no network call. Prints nothing on failure.
detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    [ -z "$ip" ] && ip="$(curl -fsS --max-time 4 https://ifconfig.me 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

# Make the stack reachable from other machines on the LAN. The published ports
# already bind 0.0.0.0 (Docker default), so TCP reachability is not the problem.
# Two things still pin the app to localhost and we fix both here:
#   1. the frontend BAKES NEXT_PUBLIC_* into the browser bundle at build time — a
#      remote browser would otherwise call its OWN localhost:4000, not this host.
#   2. the backend CORS allow-list is exact-match, so an unknown Origin is denied.
# The backend CORS allow-list (exact match) is built here from, in dev:
#   • localhost + 127.0.0.1            (always)
#   • the host LAN IP                  (auto-detected; HOST_IP=... to pin, =localhost to skip)
#   • the host PUBLIC IP               (optional; PUBLIC_IP=auto to detect, or a literal IP)
#   • any extra origins / domains      (EXTRA_ORIGINS=https://app.example.com,...)
# all at the frontend port (EXTRA_ORIGINS are taken verbatim, so they can carry
# their own scheme/host/port). localhost stays in the list so local browsing is
# unaffected. The browser bundle (NEXT_PUBLIC_*) can only target ONE host, so it
# points at the LAN IP by default — override with ADVERTISE_HOST=... (e.g. your
# public IP or domain) or by pinning NEXT_PUBLIC_* in .env.docker.
configure_lan_access() {
  local fp="${FRONTEND_PORT:-3000}" bp="${BACKEND_PORT:-4000}"

  # ── LAN IP (auto) ──────────────────────────────────────────────────────────
  HOST_IP="${HOST_IP:-$(detect_host_ip)}"
  case "$HOST_IP" in localhost|127.0.0.1) HOST_IP="" ;; esac   # explicit localhost-only opt-out
  [ -n "$HOST_IP" ] && export HOST_IP \
    || warn "no LAN IP detected — remote access limited (set HOST_IP=... to force)"

  # ── public IP (opt-in) ─────────────────────────────────────────────────────
  local public_ip="${PUBLIC_IP:-}"
  if [ "$public_ip" = "auto" ]; then
    public_ip="$(detect_public_ip)"
    [ -n "$public_ip" ] && c "detected public IP: $public_ip" \
                        || warn "PUBLIC_IP=auto but detection failed (skipping public origin)"
  fi

  # ── what the browser bundle talks to (single host) ─────────────────────────
  local advertise="${ADVERTISE_HOST:-$HOST_IP}"
  if [ -n "$advertise" ]; then
    case "${NEXT_PUBLIC_BACKEND_HOST:-}" in
      ''|http://localhost:*|http://127.0.0.1:*) export NEXT_PUBLIC_BACKEND_HOST="http://$advertise:$bp" ;;
    esac
    case "${NEXT_PUBLIC_GRAPHQL_API_URL:-}" in
      ''|http://localhost:*|http://127.0.0.1:*) export NEXT_PUBLIC_GRAPHQL_API_URL="http://$advertise:$bp/graphql" ;;
    esac
    case "${APP_HOST:-}"    in ''|localhost|127.0.0.1) export APP_HOST="$advertise" ;; esac
    case "${GRAPHIC_HOST:-}" in ''|localhost|127.0.0.1) export GRAPHIC_HOST="$advertise" ;; esac
  fi

  # ── CORS allow-list (HTTP/GraphQL/uploads + socket.io) ─────────────────────
  local origins="${ALLOWED_ORIGINS:-}"
  [ -z "$origins" ] && origins="http://localhost:$fp,http://127.0.0.1:$fp"
  local h o
  for h in localhost 127.0.0.1 "$HOST_IP" "$public_ip"; do
    [ -n "$h" ] || continue
    o="http://$h:$fp"
    case ",$origins," in *",$o,"*) ;; *) origins="$origins,$o" ;; esac
  done
  # EXTRA_ORIGINS: full origins appended verbatim (domains, https, custom ports).
  if [ -n "${EXTRA_ORIGINS:-}" ]; then
    local e oldifs="$IFS"; IFS=','
    for e in $EXTRA_ORIGINS; do
      e="$(printf '%s' "$e" | tr -d '[:space:]')"
      [ -n "$e" ] || continue
      case ",$origins," in *",$e,"*) ;; *) origins="$origins,$e" ;; esac
    done
    IFS="$oldifs"
  fi
  export ALLOWED_ORIGINS="$origins"
  # socket.io reads ALLOWED_ORIGINS too (see SocketService); keep FRONTEND_URL aligned
  # for any older code path that still reads it.
  export FRONTEND_URL="$origins"
}

# Ensure a key exists in $ENV_FILE; append "KEY=default" (with an optional
# leading comment) only when it is not already defined. Idempotent — safe to run
# on every command. Keeping these in the env FILE (not just an exported shell
# var) matters because the KVM path runs the engine through sudo, which resets
# the environment — compose still reads the file via --env-file under sudo.
ensure_env_key() {
  local key="$1" default="$2" comment="${3:-}"
  grep -qE "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null && return 0
  { [ -n "$comment" ] && printf '\n# %s\n' "$comment"; printf '%s=%s\n' "$key" "$default"; } >> "$ENV_FILE"
  c "added $key to $ENV_FILE (default: $default)"
}

# UPSERT KEY=val in an env FILE: rewrite the line if present, else append. Unlike
# ensure_env_key (add-if-absent), this is for OPERATOR-TOGGLED knobs that must
# persist across runs (e.g. INFINIBAY_CLUSTER_MTLS, NODE_KVM) — so a later bare
# `up`/`node up` keeps the last choice instead of silently reverting.
upsert_env() {
  local file="$1" key="$2" val="$3"
  if [ -f "$file" ] && grep -qE "^[[:space:]]*${key}=" "$file"; then
    sed -i "s#^[[:space:]]*${key}=.*#${key}=${val}#" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# Multi-node MASTER bootstrap. dev.sh always brings THIS host up as the cluster
# master (the default role is already 'master' in the backend). The cluster token
# gates the pre-mTLS heartbeat channel that compute-node agents use to register;
# without it the master throws "INFINIBAY_CLUSTER_TOKEN is not set" the moment it
# dispatches to any node. A stable node name lets the master re-adopt its own Node
# row (and its VMs) across container recreates instead of registering a random one.
ensure_master_env() {
  ensure_env_key INFINIBAY_NODE_NAME    master                     "multi-node: stable identity of this master node"
  ensure_env_key INFINIBAY_NODE_ROLE    master                     "multi-node: this dev host is the cluster master"
  ensure_env_key INFINIBAY_CLUSTER_TOKEN dev-insecure-cluster-token "multi-node: cluster bootstrap secret (DEV ONLY — use openssl rand -hex 32 for real multi-host)"
  # Setup-system defaults (safe for existing files / non-interactive runs that skip
  # the TUI): managed DB on, published ports bound to all interfaces.
  ensure_env_key COMPOSE_PROFILES       managed-db                 "compose profiles active (managed-db → run the bundled postgres; the TUI clears this for an external DB)"
  ensure_env_key PORT_BIND              0.0.0.0                    "host interface published ports bind to (127.0.0.1 = loopback-only, or a LAN IP = pin the NIC)"
}

# Phase A first-run bootstrap gate. True when the SETUP_DONE marker is absent AND
# this is an interactive TTY. Non-interactive/CI runs skip the TUI and use whatever
# .env.docker holds, preserving prior behavior. Set SETUP_SKIP=1 to force-skip.
setup_needed() {
  [ "${SETUP_SKIP:-0}" = 1 ] && return 1
  [ -t 0 ] || return 1
  grep -qE '^[[:space:]]*SETUP_DONE=1' "$ENV_FILE" 2>/dev/null && return 1
  return 0
}

# Run the Phase A TUI (setup-tui/): it collects pre-boot config, writes .env.docker
# and appends SETUP_DONE=1. Prefers host Node; falls back to an ephemeral node:20
# container (which also runs the external-DB probe from the backend's network view).
# $1 non-empty → reconfigure mode (re-run even with SETUP_DONE; preserves secrets).
run_setup_tui() {
  local reconfigure="${1:-}" tui_dir="./setup-tui" host_ip
  host_ip="$(detect_host_ip)"
  if command -v node >/dev/null 2>&1; then
    if [ ! -d "$tui_dir/node_modules" ]; then
      c "installing setup-tui dependencies (first run)…"
      ( cd "$tui_dir" && npm install --no-audit --no-fund --loglevel=error ) || { warn "setup-tui dependency install failed"; return 1; }
    fi
    node "$tui_dir/src/index.js" --env-file "$ENV_FILE" --host-ip "$host_ip" ${reconfigure:+--reconfigure}
  else
    c "host Node not found — running the setup TUI in a node:20 container"
    $ENGINE_SUDO docker run --rm -it -v "$PWD:/work" -w /work/setup-tui docker.io/library/node:20 \
      sh -lc "npm install --no-audit --no-fund --loglevel=error && node src/index.js --env-file \"/work/$ENV_FILE\" --host-ip '$host_ip' ${reconfigure:+--reconfigure}"
  fi
}

# Pick a Compose Spec v2 provider. These files use v2-only features (top-level
# `name:`, x-* anchors, `depends_on: { condition }`, YAML `<<: *merge`), so the
# legacy python docker-compose v1 rejects them with
#   ERROR: '<key>' does not match any of the regexes: '^x-'
# On podman hosts the podman-docker `docker compose` shim can silently delegate
# to a v1 docker-compose, so prefer the native podman-compose (spec-capable);
# fall back to a real `docker compose` v2, else fail with install guidance.
resolve_compose() {
  if command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(podman-compose)
  elif docker compose version 2>/dev/null | grep -qiE 'v?2\.'; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1 \
       && docker-compose version --short 2>/dev/null | grep -qE '^v?2\.'; then
    COMPOSE_CMD=(docker-compose)
  else
    die "no Compose v2 provider found. These compose files use v2-only features that legacy docker-compose v1 cannot parse ('name' does not match ... '^x-'). Install one:
    sudo apt-get install -y podman-compose      # native podman (recommended here)
    # — or the Docker Compose v2 plugin / standalone 'docker compose' binary"
  fi
  c "compose provider: ${COMPOSE_CMD[*]}"
}

ensure_env() {
  require docker
  resolve_compose
  ensure_podman_registries
  if [ ! -f "$ENV_FILE" ]; then
    c "creating $ENV_FILE from $ENV_EXAMPLE (edit it to change ports/creds)"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  ensure_master_env
  # Persist an operator-toggled cluster-mTLS choice (--mtls/--no-mtls) into the env
  # FILE so it survives — otherwise a later bare `up` would recreate the backend
  # WITHOUT mTLS, stop the :4433 ops server, and silently drop an enrolled mTLS node.
  if [ -n "${WANT_MTLS:-}" ]; then
    upsert_env "$ENV_FILE" INFINIBAY_CLUSTER_MTLS "$WANT_MTLS"
    c "cluster mTLS persisted → INFINIBAY_CLUSTER_MTLS=$WANT_MTLS ($ENV_FILE)"
  fi
  # Phase A: first-run setup TUI (writes .env.docker + SETUP_DONE=1) BEFORE we
  # source the file, so the collected values take effect this run. Skipped on
  # non-interactive/CI runs and once SETUP_DONE is present.
  if setup_needed || [ "${WANT_RECONFIGURE:-0}" = 1 ]; then
    run_setup_tui "${WANT_RECONFIGURE:-}" || die "setup cancelled"
  fi
  # shellcheck disable=SC1090
  set -a; . "./$ENV_FILE"; set +a
  REPOS_DIR="${REPOS_DIR:-./repos}"
  REPO_REF="${REPO_REF:-main}"
  # External DB (DATABASE_URL set by the TUI): overlay the override that points the
  # backend at it. The bundled postgres is already excluded via COMPOSE_PROFILES.
  if [ -n "${DATABASE_URL:-}" ]; then
    COMPOSE_FILES+=(-f docker-compose.external-db.yml)
    c "external database configured — bundled postgres disabled"
  fi
  detect_runtime
  # Multi-node cluster emulation: fold in the compute-node agents (node-1/node-2)
  # so the master reports multiple nodes online. Opt-in via --cluster.
  if [ "${WANT_CLUSTER:-0}" = 1 ]; then
    COMPOSE_FILES+=(-f docker-compose.cluster.yml)
    c "cluster emulation ON — adds compute-node agents (node-1, node-2)"
  fi
  configure_lan_access
}

# Clone a repo if absent (frontend pulls its harbor submodule too). Existing
# checkouts are left exactly as-is so local edits survive — use `pull` to update.
clone_one() {
  local name="$1"; local dir="$REPOS_DIR/$name"
  if [ -d "$dir/.git" ]; then
    return 0
  fi
  mkdir -p "$REPOS_DIR"
  c "cloning $name (ref: $REPO_REF)…"
  # frontend carries the harbor submodule; handled explicitly to stay bash-3.2 safe
  if [ "$name" = "frontend" ]; then
    if command -v gh >/dev/null 2>&1; then
      gh repo clone "$GH_ORG/$name" "$dir" -- --recurse-submodules || die "gh clone of $name failed"
    else
      git clone --recurse-submodules "https://github.com/$GH_ORG/$name.git" "$dir" \
        || die "git clone of $name failed (private repo? authenticate gh or git first)"
    fi
  else
    if command -v gh >/dev/null 2>&1; then
      gh repo clone "$GH_ORG/$name" "$dir" || die "gh clone of $name failed"
    else
      git clone "https://github.com/$GH_ORG/$name.git" "$dir" \
        || die "git clone of $name failed (private repo? authenticate gh or git first)"
    fi
  fi
  git -C "$dir" checkout "$REPO_REF" 2>/dev/null || warn "$name: could not checkout $REPO_REF (using default branch)"
  if [ "$name" = "frontend" ]; then
    c "initialising harbor submodule (pinned)…"
    git -C "$dir" submodule update --init --recursive || warn "harbor submodule init failed — frontend build will break until fixed"
  fi
}

clone_all() { local r; for r in "${REPOS[@]}"; do clone_one "$r"; done; }

# Fast-forward to latest origin/<ref>. Refuses to discard uncommitted edits.
pull_one() {
  local name="$1"; local dir="$REPOS_DIR/$name"
  [ -d "$dir/.git" ] || { clone_one "$name"; return; }
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    warn "$name has local changes — skipping pull (commit/stash to update)."
    return
  fi
  c "updating $name → origin/$REPO_REF…"
  git -C "$dir" fetch origin "$REPO_REF" --tags --quiet || { warn "$name fetch failed"; return; }
  git -C "$dir" checkout "$REPO_REF" --quiet 2>/dev/null || true
  git -C "$dir" merge --ff-only "origin/$REPO_REF" --quiet || warn "$name not fast-forwardable — resolve manually"
  if [ "$name" = "frontend" ]; then
    git -C "$dir" submodule update --init --recursive --quiet || warn "harbor submodule update failed"
  fi
}

pull_all() { local r; for r in "${REPOS[@]}"; do pull_one "$r"; done; }

# $ENGINE_SUDO is "" normally, or "sudo" when rootless podman needs rootful access
# for the VM path (set by detect_runtime). Unquoted so empty expands to nothing.
#
# INFINIZATION_DISABLE_SANDBOX (the --sandbox/--no-sandbox toggle) must reach the
# `docker compose` interpolation. When ENGINE_SUDO=sudo the engine runs rootful,
# and sudo resets the environment by default — so an exported var would be lost.
# We forward it explicitly via `env VAR=val` AFTER sudo (env runs as the target
# user and sets the var, bypassing sudo's env_reset). When the var is unset the
# array is empty and dc() behaves exactly as before.
dc() {
  # Vars set by flags (--sandbox / --mtls) reach compose interpolation via `env VAR=val`
  # AFTER sudo, because sudo's env_reset would otherwise drop the shell export on the
  # KVM (rootful-podman) path. Empty array → dc behaves exactly as before.
  local envfwd=() envvars=()
  [ -n "${INFINIZATION_DISABLE_SANDBOX:-}" ] && envvars+=("INFINIZATION_DISABLE_SANDBOX=$INFINIZATION_DISABLE_SANDBOX")
  [ -n "${INFINIBAY_CLUSTER_MTLS:-}" ] && envvars+=("INFINIBAY_CLUSTER_MTLS=$INFINIBAY_CLUSTER_MTLS")
  [ ${#envvars[@]} -gt 0 ] && envfwd=(env "${envvars[@]}")
  # Turn COMPOSE_PROFILES (comma list) into explicit --profile flags. Passing them
  # on the CLI works on both docker compose AND podman-compose, whereas relying on
  # the COMPOSE_PROFILES env var alone is not honored by every provider (and sudo
  # strips the environment on the KVM path anyway).
  local profile_flags=()
  if [ -n "${COMPOSE_PROFILES:-}" ]; then
    local _oldifs="$IFS" p; IFS=','
    for p in $COMPOSE_PROFILES; do [ -n "$p" ] && profile_flags+=(--profile "$p"); done
    IFS="$_oldifs"
  fi
  $ENGINE_SUDO ${envfwd[@]+"${envfwd[@]}"} "${COMPOSE_CMD[@]}" --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" ${profile_flags[@]+"${profile_flags[@]}"} "$@"
}

# ── infiniservice guest agent ────────────────────────────────────────────────
# The backend serves the compiled in-guest agent to Linux/Windows guests over HTTP
# (GET /infiniservice/<platform>/binary), reading it from the shared infinibay_base
# volume at $INFINIBAY_BASE_DIR/infiniservice/binaries/<platform>/. It is NOT built
# by the normal image build, so a fresh checkout — or a `down -v`/`clean` that wiped
# the volume — has none, and guests would 404 the agent and never phone home.

# deploy.sh writes the Linux ELF and the Windows .exe together, so the Linux binary
# is a reliable "already compiled?" signal. Path is relative to the volume root.
INFINISERVICE_BUILT_MARKER="infiniservice/binaries/linux/infiniservice"

# Returns 0 if the agent is already compiled into the infinibay_base volume. Reads
# the volume's host mountpoint, so it works before the stack is up and needs no
# helper image. Runs through $ENGINE_SUDO so it inspects the same (rootless or
# rootful) volume `dc` uses. Any uncertainty (no volume / no mountpoint) → 1.
infiniservice_built() {
  local vol mp
  vol="$($ENGINE_SUDO docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '_infinibay_base$' | head -n1 || true)"
  [ -n "$vol" ] || return 1
  mp="$($ENGINE_SUDO docker volume inspect -f '{{ .Mountpoint }}' "$vol" 2>/dev/null || true)"
  [ -n "$mp" ] || return 1
  $ENGINE_SUDO test -f "$mp/$INFINISERVICE_BUILT_MARKER"
}

# Cross-compile the agent (Windows .exe + Linux ELF) into infinibay_base. Slow.
build_infiniservice() {
  clone_one infiniservice
  c "cross-compiling infiniservice (Windows .exe + Linux ELF)… this is slow."
  dc --profile builders run --rm --build infiniservice-builder
}

# ── compute-node path (./dev.sh join / node …) ───────────────────────────────
# Lightweight env setup for a COMPUTE NODE. Unlike ensure_env (master) it pulls in
# no master compose overlays, runs no setup TUI, and seeds no master identity — a
# node's runtime config lives in .env.node, written by the join flow below.
# $1 = "start" when the caller will actually (re)start the node container — only then
# do we run the heavy privileged setup (host modprobe + /etc registries drop-in).
# Read-only ops (logs/status/down) still get the compose-file list + ENGINE_SUDO so
# they target the right (rootful, under --kvm) stack, but skip the modprobe/sudo work.
prepare_node_env() {
  require docker
  resolve_compose
  ensure_podman_registries
  REPOS_DIR="${REPOS_DIR:-./repos}"
  REPO_REF="${REPO_REF:-main}"
  PORT_BIND="${PORT_BIND:-0.0.0.0}"
  detect_node_runtime "${1:-}"
}

# Compute-node KVM decision. OPT-IN via --kvm (NODE_KVM=on) — unlike the master's
# auto-detect — because enabling it layers the privileged KVM overlay AND (under
# rootless podman) routes the node engine through sudo/rootful, which re-namespaces
# the node's volumes; we don't silently flip an already-rootless node. When on: layer
# the node KVM overlay so a MIGRATED VM can boot here, default the QEMU sandbox off
# (rootless-podman SIGSYS), load host bridge modules, and use rootful podman for host
# bridges/nft/TAP — mirrors the master's detect_runtime.
detect_node_runtime() {
  local starting="${1:-}"
  # Effective KVM choice: the --kvm flag (exported NODE_KVM) wins; else whatever a
  # prior `join`/`node up --kvm` persisted in .env.node; else off.
  local kvm="${NODE_KVM:-}"
  [ -z "$kvm" ] && kvm="$(grep -E '^[[:space:]]*NODE_KVM=' "$NODE_ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  case "$kvm" in
    on|1|true) ;;
    *) c "node: heartbeat/enroll only (rootless). Pass --kvm so MIGRATED VMs can boot on this host."; return 0 ;;
  esac
  { [ "$(uname -s)" = "Linux" ] && [ -e /dev/kvm ]; } \
    || die "node --kvm needs /dev/kvm on this host (Linux + hardware virtualization). Omit --kvm to run heartbeat-only."
  NODE_COMPOSE_FILES+=(-f "$NODE_KVM_COMPOSE_FILE")
  KVM_ACTIVE=1
  export INFINIZATION_DISABLE_SANDBOX="${INFINIZATION_DISABLE_SANDBOX:-1}"
  c "node: KVM ON — migrated VMs can boot here (/dev/kvm present)."
  if docker --version 2>&1 | grep -qi podman \
     && [ "$(id -u)" -ne 0 ] \
     && docker info 2>/dev/null | grep -q "rootless: true"; then
    command -v sudo >/dev/null 2>&1 \
      || die "rootless podman + node KVM needs rootful access but 'sudo' is missing. Install sudo, or run as root."
    ENGINE_SUDO="sudo"
    # IMPORTANT: rootful podman uses a DIFFERENT volume/image namespace than rootless.
    # A node first joined WITHOUT --kvm (rootless) has its enrollment cert + node_modules
    # in the ROOTLESS namespace; enabling --kvm now can't see them → the agent re-enrolls
    # as a duplicate and re-installs. If you enrolled rootless and now want KVM, tear the
    # rootless stack down (`./dev.sh node down`) and re-run `./dev.sh join --kvm`.
    warn "node --kvm ⇒ rootful podman (sudo). Its volumes are a SEPARATE namespace from a rootless enrollment — if you first joined WITHOUT --kvm, down the node and re-join with --kvm. You may be prompted for your password."
    [ "$starting" = start ] && ensure_root_registries
  fi
  # modprobe of host bridge modules is only needed when we actually boot QEMU.
  [ "$starting" = start ] && ensure_host_modules
}

# Compose wrapper for the compute-node stack (node.yml [+ node.kvm.yml] + .env.node).
# $ENGINE_SUDO is "" for the heartbeat-only path, "sudo" once --kvm needs rootful
# podman for VM networking; envfwd carries the sandbox toggle across sudo's env-reset.
dc_node() {
  local envfwd=() envvars=()
  [ -n "${INFINIZATION_DISABLE_SANDBOX:-}" ] && envvars+=("INFINIZATION_DISABLE_SANDBOX=$INFINIZATION_DISABLE_SANDBOX")
  [ ${#envvars[@]} -gt 0 ] && envfwd=(env "${envvars[@]}")
  $ENGINE_SUDO ${envfwd[@]+"${envfwd[@]}"} "${COMPOSE_CMD[@]}" --env-file "$NODE_ENV_FILE" "${NODE_COMPOSE_FILES[@]}" "$@"
}

# Absolute HOST path of the node's base volume (namespace-correct via $ENGINE_SUDO —
# rootless and rootful podman keep SEPARATE volumes), or non-zero if it doesn't exist
# yet. Lets `join` peek at / wipe the enrollment cert without running a container.
node_base_mountpoint() {
  local vol
  vol="$($ENGINE_SUDO docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E 'node_infinibay_base$' | head -n1 || true)"
  [ -n "$vol" ] || return 1
  $ENGINE_SUDO docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || return 1
}

# Delete the node's enrollment identity (cert/key/CA/join-state) from its base volume
# so `join.ts` pairs fresh instead of short-circuiting on an existing cert. $1 = the
# volume mountpoint (from node_base_mountpoint). Leaves disks/node_modules untouched.
node_wipe_enrollment() {
  local mp="$1"
  $ENGINE_SUDO rm -f "$mp"/certs/node-cert.pem "$mp"/certs/node-key.pem \
                     "$mp"/certs/cluster-ca.pem "$mp"/certs/join-state.json
}

# The cluster bootstrap token to OFFER as the default: the one already in the local
# .env.docker if present, else the shipped dev default from .env.docker.example.
# (It only works if the master kept that same token — otherwise paste the master's.)
node_default_token() {
  local t=""
  # `|| true`: under set -o pipefail, `grep|head` returns non-zero on no-match OR when
  # head closes the pipe early (grep SIGPIPE) — either would abort the script via set -e.
  t="$(grep -E '^[[:space:]]*INFINIBAY_CLUSTER_TOKEN=' "$ENV_FILE"    2>/dev/null | head -n1 | cut -d= -f2- || true)"
  [ -n "$t" ] || t="$(grep -E '^[[:space:]]*INFINIBAY_CLUSTER_TOKEN=' "$ENV_EXAMPLE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  printf '%s' "$t"
}

# Onboard THIS host as a compute node of a remote master. The operator supplies the
# master URL (arg or prompt), picks the token, runs the SAS-verified enrollment, then
# starts the heartbeat so the node reports online. See docker-compose.node.yml.
cmd_join() {
  # mTLS is ON BY DEFAULT for join: a real remote node exists to receive migrated
  # VMs, and the disk copy is mTLS-only. `--no-mtls` opts down to the dev token
  # channel (same-host emulation / a master still in token mode).
  local master_url="" node_name="" token="" want_mtls=1 master_cn="" no_start=0 node_kvm=off reenroll=0
  # first non-flag positional is the master URL
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)      node_name="${2:-}"; shift 2 ;;
      --token)     token="${2:-}"; shift 2 ;;
      --master-cn) master_cn="${2:-}"; shift 2 ;;
      --mtls)      want_mtls=1; shift ;;   # explicit (already the default)
      --no-mtls|--token-mode) want_mtls=0; shift ;;
      --kvm)       node_kvm=on; shift ;;
      --reenroll|--force) reenroll=1; shift ;;   # skip the prompt: wipe the old cert + pair fresh
      --no-start)  no_start=1; shift ;;
      -h|--help)   cmd_join_help; return 0 ;;
      -*)          die "join: unknown flag '$1' (see ./dev.sh join --help)" ;;
      *)           [ -z "$master_url" ] && master_url="$1" || die "join: unexpected argument '$1'"; shift ;;
    esac
  done

  export NODE_KVM="$node_kvm"   # detect_node_runtime (via prepare_node_env) reads this
  prepare_node_env start        # join (re)starts the node container → do the privileged setup

  # ── 0. existing enrollment? decide use-it vs re-enroll ─────────────────────
  # `join.ts` short-circuits when a node-cert.pem already exists ("nothing to do").
  # That silently strands you when you actually wanted to re-pair (e.g. the master
  # was rebuilt / forgot this node, so its old cert no longer verifies). Detect the
  # cert HERE and let the operator choose — or wipe it up front with --reenroll.
  local _mp; _mp="$(node_base_mountpoint || true)"
  if [ -n "$_mp" ] && $ENGINE_SUDO test -f "$_mp/certs/node-cert.pem" 2>/dev/null; then
    local _act=u
    if [ "$reenroll" = 1 ]; then
      _act=r
    elif [ -t 0 ]; then
      warn "this node already has an enrollment cert (in volume: $_mp/certs/node-cert.pem)."
      c "  [u] use it — just (re)start the heartbeat        (= ./dev.sh node up)"
      c "  [r] re-enroll — delete the cert + pair again     (new 6-digit code)"
      c "  [c] cancel"
      local _ans; read -r -p "$(printf '\033[1;36m[dev]\033[0m Choice [u/r/c] (default u): ')" _ans || true
      case "$_ans" in r|R|rejoin) _act=r ;; c|C) c "cancelled — nothing changed."; return 0 ;; *) _act=u ;; esac
    fi
    if [ "$_act" = u ]; then
      c "using the existing enrollment — (re)starting the heartbeat…"
      clone_one backend; clone_one infinization
      dc_node up -d --build node-agent
      c "node heartbeating with its existing cert. Re-pair later with: ./dev.sh join <master> --reenroll"
      return 0
    fi
    c "re-enrolling — removing the old cert + join state so pairing starts fresh…"
    node_wipe_enrollment "$_mp"
  fi

  c "onboarding THIS host as a compute node — cloning backend + infinization…"
  clone_one backend
  clone_one infinization

  # ── 1. master URL (REQUIRED — no auto-discovery) ───────────────────────────
  # Onboarding is a trust boundary: the operator supplies the master endpoint
  # explicitly (arg or prompt) and verifies it via the SAS pairing. This is what
  # every serious cluster join does (k3s/swarm/kubeadm) and works across routed
  # networks, unlike LAN-only discovery.
  if [ -z "$master_url" ]; then
    if [ -t 0 ]; then
      read -r -p "$(printf '\033[1;36m[dev]\033[0m Master IP or URL (e.g. 192.168.1.50 or http://192.168.1.50:4000): ')" master_url || true
    fi
    [ -n "$master_url" ] || die "the master URL is required: ./dev.sh join http://<master-ip>:4000  (find the IP on the master with: hostname -I)"
  fi
  # Accept a bare host/IP → prepend http:// and default the port to :4000, while
  # preserving an explicit scheme/port/path if the operator typed a full URL.
  case "$master_url" in http://*|https://*) ;; *) master_url="http://$master_url" ;; esac
  local _sch="${master_url%%://*}" _rest="${master_url#*://}" _path=""
  local _hp="${_rest%%/*}"
  if [ "$_rest" != "$_hp" ]; then _path="/${_rest#*/}"; fi
  case "$_hp" in *:*) ;; *) _hp="${_hp}:4000" ;; esac
  master_url="${_sch}://${_hp}${_path}"
  c "master: ${master_url}"

  # ── 2. node name ───────────────────────────────────────────────────────────
  [ -n "$node_name" ] || node_name="$(hostname 2>/dev/null || echo node)"

  # ── 3. token: offer the .env.docker default, or paste the master's ─────────
  if [ -z "$token" ]; then
    local def; def="$(node_default_token)"
    if [ -t 0 ]; then
      if [ -n "$def" ]; then
        read -r -p "$(printf '\033[1;36m[dev]\033[0m Cluster token [Enter = use %s from %s]: ' "$def" "$ENV_FILE")" token || true
        [ -n "$token" ] || token="$def"
      else
        read -r -p "$(printf '\033[1;36m[dev]\033[0m Paste the master'\''s cluster token: ')" token || true
      fi
    else
      token="$def"
    fi
  fi
  [ -n "$token" ] || die "a cluster token is required (get it on the master: grep INFINIBAY_CLUSTER_TOKEN .env.docker)"

  # ── 4. mTLS derivations (opt-in) ───────────────────────────────────────────
  local mtls_flag=0 master_cluster_url="" node_address
  node_address="$(detect_host_ip)"
  if [ "$want_mtls" = 1 ]; then
    mtls_flag=1
    [ -n "$master_cn" ] || master_cn="master"   # master's cert CN = its INFINIBAY_NODE_NAME (dev default: master)
    local mh="${master_url#*://}"; mh="${mh%%/*}"; mh="${mh%%:*}"
    master_cluster_url="https://${mh}:${INFINIBAY_CLUSTER_PORT:-4433}"
    warn "heartbeat in full mTLS (default) — the MASTER must run with INFINIBAY_CLUSTER_MTLS=1 (its :4433 ops server) and its node name must be '${master_cn}' (override with --master-cn). If the master is still token-mode, re-run with --no-mtls."
  fi

  # ── 5. validate everything that lands in .env.node ─────────────────────────
  [[ "$master_url" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\'\(\)*+,\;=%-]+$ ]] || die "master URL has unexpected characters: $master_url"
  [[ "$token"      =~ ^[A-Za-z0-9._+=/:-]+$ ]] || die "token has characters outside [A-Za-z0-9._+=/:-]"
  [[ "$node_name"  =~ ^[A-Za-z0-9._-]+$ ]]     || die "node name must match [A-Za-z0-9._-]: $node_name"

  # ── 6. write .env.node (consumed by dc_node) ───────────────────────────────
  {
    echo "# Generated by ./dev.sh join — compute-node runtime config. DO NOT COMMIT."
    echo "REPOS_DIR=$REPOS_DIR"
    echo "PORT_BIND=$PORT_BIND"
    echo "MASTER_URL=$master_url"
    echo "INFINIBAY_NODE_NAME=$node_name"
    echo "INFINIBAY_CLUSTER_TOKEN=$token"
    echo "INFINIBAY_CLUSTER_MTLS=$mtls_flag"
    echo "MASTER_CLUSTER_URL=$master_cluster_url"
    echo "INFINIBAY_MASTER_CN=$master_cn"
    echo "NODE_ADDRESS=$node_address"
    echo "NODE_KVM=$node_kvm"
  } > "$NODE_ENV_FILE"
  c "wrote $NODE_ENV_FILE"

  # ── 7. enrollment (interactive — prints the SAS pairing code) ──────────────
  echo ""
  c "=== Joining cluster as node '${node_name}' ==="
  c "  Master:    ${master_url}"
  c "  Node name: ${node_name}"
  c "  Heartbeat: $([ "$mtls_flag" = 1 ] && echo 'mTLS' || echo 'token mode')"
  echo ""
  warn "A 6-digit PAIRING CODE prints below. Compare it with the code shown for this"
  warn "node in the master's Infrastructure UI, then APPROVE it there. If the codes"
  warn "differ, the connection may be tampered with — do NOT approve."
  echo ""
  # Invoke via `node` + ts-node as a require hook (NOT node_modules/.bin/ts-node,
  # which rootless podman may refuse to exec from the volume). Same as `npm run
  # agent:join` (ts-node -r tsconfig-paths/register agent/join.ts).
  if ! dc_node run --rm node-agent node -r ts-node/register -r tsconfig-paths/register agent/join.ts; then
    die "enrollment failed. Check the master URL/token, that the master is reachable, and that it has INFINIBAY_CLUSTER_TOKEN set."
  fi

  # ── 8. heartbeat (long-running) ────────────────────────────────────────────
  if [ "$no_start" = 1 ]; then
    c "enrollment done (--no-start). Start the heartbeat later with: ./dev.sh node up"
    return 0
  fi
  c "approved — starting the heartbeat agent (first start builds infinization; slow, one-time)…"
  dc_node up -d --build node-agent
  echo ""
  c "node '${node_name}' is enrolled and heartbeating → it should appear ONLINE in the master UI."
  c "  logs:    ./dev.sh node logs"
  c "  status:  ./dev.sh node status"
  c "  stop:    ./dev.sh node down"
  [ "$mtls_flag" != 1 ] && c "  (heartbeat is in dev token mode via --no-mtls; cross-node VM migration needs mTLS — re-run without --no-mtls)"
}

cmd_join_help() {
  cat <<'EOF'
Usage: ./dev.sh join [master-url] [options]

Onboard THIS host as a compute node of a remote Infinibay master (Docker dev
stack). You supply the master URL (as an argument or when prompted), it picks the
cluster token, runs the SAS-verified enrollment, then starts the heartbeat so the
node reports online.

Arguments:
  master-url        the master's IP or URL, e.g. 192.168.1.50 or http://192.168.1.50:4000
                    (a bare IP is expanded to http://<ip>:4000). REQUIRED — if omitted
                    you are prompted for it. Find it on the master with: hostname -I

Options:
  --name NODE       node name (default: this host's hostname)
  --token TOKEN     cluster bootstrap token (default: prompt, offering the one in
                    .env.docker). Get it on the master: grep INFINIBAY_CLUSTER_TOKEN .env.docker
  --mtls            heartbeat over full mutual TLS. THIS IS THE DEFAULT (explicit flag
                    kept for clarity) — a real remote node exists to receive cross-node
                    VM MIGRATIONS and the disk copy is mTLS-only. Needs the master
                    started with `./dev.sh up --mtls` (its :4433 ops server).
  --no-mtls         opt down to the dev token heartbeat channel (same-host emulation,
                    or a master still in token mode). Cross-node migration won't work.
  --master-cn CN    master certificate CN for mTLS (default: master)
  --kvm             give the node /dev/kvm + host networking so a MIGRATED VM can
                    actually BOOT here (opt-in; layers docker-compose.node.kvm.yml and,
                    under rootless podman, uses sudo/rootful — re-namespaces volumes).
                    Requires /dev/kvm and your user in the `kvm` group on this host.
  --reenroll        if this node is already enrolled, delete its cert and pair again
                    (skips the interactive prompt). Alias: --force.
  --no-start        enroll only; don't start the heartbeat

If the node already holds an enrollment cert, join ASKS whether to use it (just start
the heartbeat, = `node up`) or re-enroll (wipe + new pairing code). --reenroll picks
re-enroll non-interactively.

Examples:
  ./dev.sh join 192.168.1.50                 # mTLS by default; bare IP → :4000
  ./dev.sh join 192.168.1.50 --kvm --name worker-1   # + boot migrated VMs here
  ./dev.sh join 192.168.1.50 --reenroll      # force a fresh pairing (wipe old cert)
  ./dev.sh join 192.168.1.50 --no-mtls       # dev token mode (no migration)
Manage the node afterwards:  ./dev.sh node logs | status | down | up [--kvm]
EOF
}

# Manage the compute-node agent started by `join` (thin dc_node passthrough).
# `node up --kvm` (re)starts it with the KVM overlay so migrated VMs can boot here.
cmd_node() {
  local sub="${1:-status}"; shift || true
  local rest=() want_kvm=0
  for a in "$@"; do case "$a" in --kvm) want_kvm=1 ;; *) rest+=("$a") ;; esac; done
  [ -f "$NODE_ENV_FILE" ] || die "no $NODE_ENV_FILE — run ./dev.sh join first."
  # Persist an explicit --kvm so later `node up`/`restart` keep the KVM overlay
  # (matches how `join` records it) — otherwise a bare `node up` would drop it.
  if [ "$want_kvm" = 1 ]; then export NODE_KVM=on; upsert_env "$NODE_ENV_FILE" NODE_KVM on; fi
  local starting=""; case "$sub" in up|restart) starting=start ;; esac
  prepare_node_env "$starting"
  case "$sub" in
    up)             dc_node up -d --build node-agent ;;
    down|stop)      dc_node down ${rest[@]+"${rest[@]}"} ;;
    logs)           dc_node logs -f ${rest[@]+"${rest[@]}"} ;;
    status|ps)      dc_node ps ${rest[@]+"${rest[@]}"} ;;
    restart)        dc_node restart node-agent ;;
    *) die "unknown node subcommand '$sub'. Try: up | down | logs | status | restart" ;;
  esac
}

cmd="${1:-up}"; shift || true

case "$cmd" in
  up)
    passthrough=()
    for a in "$@"; do
      case "$a" in
        --kvm)    export KVM=on ;;
        --no-kvm) export KVM=off ;;
        # QEMU seccomp sandbox toggle. DEFAULT is OFF (the compose default,
        # INFINIZATION_DISABLE_SANDBOX=1): this dev stack runs QEMU inside a
        # rootless-podman container whose substrate kills a sandboxed device-init
        # syscall with SIGSYS, so VMs would fail to boot with the sandbox on.
        # Pass --sandbox to opt back INTO QEMU's seccomp sandbox (defense-in-depth)
        # on a substrate where it works.
        --sandbox)    export INFINIZATION_DISABLE_SANDBOX=0
                      c "QEMU seccomp sandbox: ON (--sandbox)" ;;
        --no-sandbox) export INFINIZATION_DISABLE_SANDBOX=1
                      c "QEMU seccomp sandbox: OFF (--no-sandbox, default)" ;;
        # Multi-node cluster emulation (docker-compose.cluster.yml): the master
        # plus node-1/node-2 compute-agent heartbeats, all on this one host. The
        # master itself always comes up as master (default); this only adds the
        # emulated compute nodes so you can watch several nodes report online.
        --cluster)    WANT_CLUSTER=1 ;;
        --no-cluster) WANT_CLUSTER=0 ;;
        # Cluster mTLS. Run the master with its :4433 ops server so REAL remote nodes
        # (joined with `./dev.sh join`, mTLS by default) can heartbeat, proxy DB-RPC, and receive
        # cross-node VM migrations over mutual TLS. Cluster-wide all-or-nothing: with
        # mTLS on, the token ops path is retired (HTTP 421), so token nodes and the
        # `--cluster` emulation go offline — hence the guard below.
        --mtls)       WANT_MTLS=1
                      c "cluster mTLS: ON — master runs its :4433 ops server (real remote mTLS nodes)" ;;
        --no-mtls)    WANT_MTLS=0
                      c "cluster mTLS: OFF — token-mode heartbeats" ;;
        # Re-run the Phase A setup TUI even when SETUP_DONE is present (preserves
        # existing secrets), then continue the normal up.
        --reconfigure) WANT_RECONFIGURE=1 ;;
        # Guest-agent build control. `up` auto-builds infiniservice when a KVM host
        # has none (see below). Bypass, or force a fresh cross-compile:
        --skip-infiniservice)    SKIP_INFINISERVICE=1 ;;
        --rebuild-infiniservice) WANT_REBUILD_INFINISERVICE=1 ;;
        *) passthrough+=("$a") ;;
      esac
    done
    ensure_env   # detect_runtime here picks control-plane vs KVM and sets ENGINE_SUDO
    # mTLS retires the token ops path (421), so token nodes can't register alongside it.
    # Evaluated AFTER ensure_env so it sees the EFFECTIVE mtls value (the --mtls flag
    # OR a value persisted in .env.docker), not just this run's flag.
    if [ "${INFINIBAY_CLUSTER_MTLS:-}" = 1 ] && [ "${WANT_CLUSTER:-0}" = 1 ]; then
      die "--mtls and --cluster are mutually exclusive: under cluster mTLS the token heartbeat path returns 421, so the emulated (token-mode) node-1/node-2 cannot register. Use --cluster for same-host token emulation, OR --mtls for real remote mTLS nodes (./dev.sh join, mTLS by default)."
    fi
    clone_all
    [ "$KVM_ACTIVE" = 1 ] && ensure_host_modules
    # Guest agent: build it once, automatically, when missing — otherwise a fresh
    # install's VMs 404 the agent (GET /infiniservice/<platform>/binary) and never
    # phone home. Detection is a cheap file check in the infinibay_base volume, so
    # this is a no-op on every later `up`. Only on a KVM host (no VMs → nothing to
    # serve it to in control-plane-only mode). Flags: --skip-infiniservice bypasses,
    # --rebuild-infiniservice forces a fresh cross-compile.
    if [ "${WANT_REBUILD_INFINISERVICE:-0}" = 1 ]; then
      c "rebuilding the infiniservice guest agent (--rebuild-infiniservice)…"
      build_infiniservice
    elif [ "${SKIP_INFINISERVICE:-0}" = 1 ]; then
      warn "--skip-infiniservice: guests will 404 the agent until you run ./dev.sh build-infiniservice."
    elif [ "$KVM_ACTIVE" != 1 ]; then
      : # control-plane-only: no VMs to serve the agent to — skip the slow build.
    elif infiniservice_built; then
      c "infiniservice guest agent already compiled — skipping build."
    else
      warn "infiniservice guest agent not compiled yet — building it now so new VMs can install it (slow, one-time)."
      build_infiniservice
    fi
    c "building images + starting stack…"
    c "first run installs all deps inside the containers — give it several minutes."
    c "  backend  → http://localhost:${BACKEND_PORT:-4000}/graphql"
    c "  frontend → http://localhost:${FRONTEND_PORT:-3000}"
    if [ -n "${HOST_IP:-}" ]; then
      c "  reachable from other devices on the LAN:"
      c "    frontend → http://${HOST_IP}:${FRONTEND_PORT:-3000}"
      c "    backend  → http://${HOST_IP}:${BACKEND_PORT:-4000}/graphql"
    fi
    # ${arr[@]+...} guard keeps an empty array from tripping set -u on bash 3.2
    dc up --build ${passthrough[@]+"${passthrough[@]}"}
    ;;
  down)    ensure_env; dc down "$@" ;;
  logs)    ensure_env; dc logs -f "$@" ;;
  status|ps) ensure_env; dc ps "$@" ;;
  restart) ensure_env; dc restart "$@" ;;
  pull)    ensure_env; pull_all ;;
  build-infiniservice)
    ensure_env; build_infiniservice
    ;;
  join|jn)  cmd_join "$@" ;;
  node)     cmd_node "$@" ;;
  clean)
    ensure_env
    warn "removing volumes (db, node_modules, caches) and built images…"
    dc --profile builders down -v --rmi local || true
    ;;
  reconfigure)
    # Re-run the Phase A setup TUI (preserving existing secrets) without starting
    # the stack. ensure_env triggers the TUI because WANT_RECONFIGURE=1.
    WANT_RECONFIGURE=1
    ensure_env
    c "Reconfigured $ENV_FILE. Run ./dev.sh up to (re)start the stack with the new settings."
    ;;
  *) die "unknown command '$cmd'. Try: up | down | logs | pull | restart | status | join | node | build-infiniservice | clean | reconfigure" ;;
esac

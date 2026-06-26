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
#   ./dev.sh build-infiniservice   cross-compile the Rust guest agent
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
ENGINE_SUDO="" # set to "sudo" when rootless podman needs rootful access for VMs
KVM_ACTIVE=0   # set to 1 by detect_runtime when the hypervisor override is enabled

REPOS=(backend frontend infinization infiniservice)
GH_ORG="Infinibay"

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

ensure_env() {
  require docker
  docker compose version >/dev/null 2>&1 || die "'docker compose' v2+ is required"
  ensure_podman_registries
  if [ ! -f "$ENV_FILE" ]; then
    c "creating $ENV_FILE from $ENV_EXAMPLE (edit it to change ports/creds)"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  # shellcheck disable=SC1090
  set -a; . "./$ENV_FILE"; set +a
  REPOS_DIR="${REPOS_DIR:-./repos}"
  REPO_REF="${REPO_REF:-main}"
  detect_runtime
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
dc() { $ENGINE_SUDO docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" "$@"; }

cmd="${1:-up}"; shift || true

case "$cmd" in
  up)
    passthrough=()
    for a in "$@"; do
      case "$a" in
        --kvm)    export KVM=on ;;
        --no-kvm) export KVM=off ;;
        *) passthrough+=("$a") ;;
      esac
    done
    ensure_env   # detect_runtime here picks control-plane vs KVM and sets ENGINE_SUDO
    clone_all
    [ "$KVM_ACTIVE" = 1 ] && ensure_host_modules
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
    ensure_env; clone_one infiniservice
    c "cross-compiling infiniservice (Windows .exe + Linux ELF)… this is slow."
    dc --profile builders run --rm --build infiniservice-builder
    ;;
  clean)
    ensure_env
    warn "removing volumes (db, node_modules, caches) and built images…"
    dc --profile builders down -v --rmi local || true
    ;;
  *) die "unknown command '$cmd'. Try: up | down | logs | pull | restart | status | build-infiniservice | clean" ;;
esac

#!/usr/bin/env bash
# Infinibay — one-command Docker dev environment.
#
#   ./dev.sh up            clone/refresh repos, then start the stack (live logs)
#   ./dev.sh up -d         same, detached
#   ./dev.sh up --kvm      also apply the Linux KVM override (Linux hosts only)
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

REPOS=(backend frontend infinization infiniservice)
GH_ORG="Infinibay"

c() { printf '\033[1;36m[dev]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dev]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dev]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

ensure_env() {
  require docker
  docker compose version >/dev/null 2>&1 || die "'docker compose' v2+ is required"
  if [ ! -f "$ENV_FILE" ]; then
    c "creating $ENV_FILE from $ENV_EXAMPLE (edit it to change ports/creds)"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  # shellcheck disable=SC1090
  set -a; . "./$ENV_FILE"; set +a
  REPOS_DIR="${REPOS_DIR:-./repos}"
  REPO_REF="${REPO_REF:-main}"
}

# Clone a repo if absent (frontend pulls its harbor submodule too). Existing
# checkouts are left exactly as-is so local edits survive — use `pull` to update.
clone_one() {
  local name="$1" dir="$REPOS_DIR/$name"
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
  local name="$1" dir="$REPOS_DIR/$name"
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

dc() { docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" "$@"; }

cmd="${1:-up}"; shift || true

case "$cmd" in
  up)
    use_kvm=0; passthrough=()
    for a in "$@"; do
      case "$a" in
        --kvm) use_kvm=1 ;;
        *) passthrough+=("$a") ;;
      esac
    done
    ensure_env
    clone_all
    [ "$use_kvm" = 1 ] && COMPOSE_FILES+=(-f docker-compose.kvm.yml)
    c "building images + starting stack…"
    c "first run installs all deps inside the containers — give it several minutes."
    c "  backend  → http://localhost:${BACKEND_PORT:-4000}/graphql"
    c "  frontend → http://localhost:${FRONTEND_PORT:-3000}"
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

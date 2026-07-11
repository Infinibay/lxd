#!/usr/bin/env bash
# Frontend dev entrypoint: install deps (with the harbor submodule present) and
# run `next dev` for hot module reload. Idempotent.
set -uo pipefail

log() { echo -e "\033[1;35m[frontend]\033[0m $*"; }
warn() { echo -e "\033[1;33m[frontend]\033[0m $*"; }

FE=/workspace/frontend
NPM_AGE_FLAG="--minimum-release-age=0"

cd "$FE"

# Fail loud if the browser-facing URLs are empty. The frontend repo ships a
# git-tracked .env with a stale LAN IP; Next would silently fall back to it if
# these were ever cleared, pointing the browser at a dead host. compose sets them.
: "${NEXT_PUBLIC_BACKEND_HOST:?must be set (see .env.docker)}"
: "${NEXT_PUBLIC_GRAPHQL_API_URL:?must be set (see .env.docker)}"

# @infinibay/harbor is a file:./harbor git submodule. If it wasn't checked out,
# `npm install` and the build both fail. ./dev.sh pulls it; fail loudly if not.
if [ ! -f harbor/package.json ]; then
  warn "harbor submodule is missing/empty at $FE/harbor."
  warn "Fix on the host:  ./dev.sh pull   (or: git -C \$REPOS_DIR/frontend submodule update --init --recursive)"
  exit 1
fi

export HUSKY=0 # no git hooks inside the container

if [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  log "installing frontend deps (first run — a few minutes)…"
  npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "frontend npm install reported errors"
fi

log "starting next dev (HMR) on :3000 → backend at ${NEXT_PUBLIC_BACKEND_HOST:-http://localhost:4000} …"

# Pre-warm the entry routes so the user's FIRST browser load isn't racing a cold
# compile. `next dev --webpack` compiles routes ON DEMAND: on a cold .next cache
# the first hit to a route takes ~20-25s, and while it compiles the page's JS
# chunks 404 ("ChunkLoadError: Loading chunk app/layout failed"). If you open the
# UI during that window the app looks broken — which is why killing the stack and
# re-`up`ing "fixed" it (the second run had a warm .next and won the race). We move
# that one-time cost off your critical path: start next dev in the background, hit
# the landing + post-login routes ourselves (a presence cookie clears the edge
# middleware so protected routes compile too — it isn't the auth boundary), THEN
# announce readiness. Best-effort: warm-up never takes the server down.
npm run dev &
NEXT_PID=$!
# Forward stop signals to next dev (we lost `exec`, so bash is the child of init).
trap 'kill -TERM "$NEXT_PID" 2>/dev/null' TERM INT

(
  # Wait for the dev server to accept connections before warming.
  for _ in $(seq 1 90); do
    curl -sf -o /dev/null --max-time 2 http://localhost:3000/ 2>/dev/null && break
    sleep 1
  done
  # /auth/sign-in first — it builds the shared app/layout chunk that was 404ing.
  # The rest are the routes you land on right after login.
  for route in /auth/sign-in /desktops /overview /settings; do
    log "pre-warming ${route} …"
    curl -s -o /dev/null --max-time 180 -H 'Cookie: infinibay-session=1' \
      "http://localhost:3000${route}" 2>/dev/null || true
  done
  log "routes pre-warmed — the UI is ready to open at :3000 (first load will be fast)."
) &

wait "$NEXT_PID"

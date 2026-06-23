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
exec npm run dev

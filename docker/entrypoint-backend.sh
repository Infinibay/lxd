#!/usr/bin/env bash
# Backend dev entrypoint: build the infinization sibling, install backend deps,
# prepare the DB, then run the backend under nodemon for hot reload.
#
# Mirrors the LXD provisioning steps (infinization built in-place with
# `npm install && npm run build`, then backend install + prisma + start).
# Difference: LXD runs pre-compiled JS (`node dist/index.js`); here we run ts-node
# under nodemon for hot reload. Full type-checking is kept ON (no transpile-only):
# TypeGraphQL infers GraphQL types from cross-file reflection metadata that
# single-file transpilation can't emit, so transpile-only makes resolvers throw
# NoExplicitTypeError at boot. Restarts are therefore a bit slower but correct.
# Idempotent: skips installs when node_modules is already populated in its volume.
set -uo pipefail

log() { echo -e "\033[1;36m[backend]\033[0m $*"; }
warn() { echo -e "\033[1;33m[backend]\033[0m $*"; }

INFZ=/workspace/infinization
BE=/workspace/backend
NPM_AGE_FLAG="--minimum-release-age=0" # sanctioned dev override of .npmrc guardrail

# ── 0. kernel-module tooling (lsmod) ─────────────────────────────────────────
# The VM-networking code probes modules with `lsmod` (and would `modprobe` on a
# miss). Those binaries live in the kmod package, which the base image omits. The
# MODULES THEMSELVES are loaded on the host by ./dev.sh — here we only need lsmod
# so the backend SEES them through the shared /proc/modules and skips modprobe
# (which can't load host modules from inside a container anyway). Guarded → the
# install runs at most once per container. No-op on hosts without VMs.
if ! command -v lsmod >/dev/null 2>&1; then
  log "installing kmod (lsmod) for host kernel-module detection…"
  (apt-get update && apt-get install -y --no-install-recommends kmod) \
    >/tmp/kmod-install.log 2>&1 || warn "kmod install failed (module checks will warn; non-fatal)"
fi

# ── 1. infinization (sibling file: dependency) ───────────────────────────────
# backend's package.json declares "@infinibay/infinization": "file:../infinization"
# and imports its COMPILED dist/index.js, so it must exist + be built first.
if [ -d "$INFZ" ]; then
  cd "$INFZ"
  if [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
    log "installing infinization deps (first run)…"
    npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "infinization npm install reported errors"
  fi
  if [ ! -f dist/index.js ]; then
    log "building infinization (tsc && tsc-alias)…"
    npm run build || warn "infinization build reported errors"
  fi
  # Background watcher → rebuilds dist/ on change so edits to infinization also
  # hot-reload the backend (nodemon watches infinization/dist below). We run the
  # FULL `npm run build` (tsc && tsc-alias) atomically per change rather than two
  # parallel -w watchers, so dist/ is never seen mid-rewrite with unresolved
  # @core/@utils path aliases (which would crash the backend with MODULE_NOT_FOUND).
  log "starting infinization rebuild-on-change watcher…"
  ( cd "$INFZ" && nodemon --quiet --watch src --ext ts --exec 'npm run build' \
      >/tmp/infz-build.log 2>&1 & ) || warn "infinization watcher failed to start"
else
  warn "infinization not found at $INFZ — backend imports will fail. Run ./dev.sh pull"
fi

# ── 2. backend deps + prisma client ──────────────────────────────────────────
cd "$BE"
if [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  log "installing backend deps (first run — this is the slow one, a few minutes)…"
  npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "backend npm install reported errors"
fi
log "prisma generate…"
npx prisma generate || warn "prisma generate reported errors"

# ── 3. wait for postgres, then migrate ───────────────────────────────────────
log "waiting for postgres at ${PGHOST:-postgres}:${PGPORT:-5432}…"
until pg_isready -h "${PGHOST:-postgres}" -p "${PGPORT:-5432}" -U "${PGUSER:-infinibay}" >/dev/null 2>&1; do
  sleep 1
done
log "applying migrations (prisma migrate deploy)…"
npx prisma migrate deploy || warn "migrate deploy reported errors (continuing)"

if [ "${RUN_SEED:-true}" = "true" ]; then
  # Run the seed only ONCE: some seed steps (Default department/category) are
  # plain creates and would accumulate duplicates on every `up`. The marker lives
  # in the persistent infinibay_base volume (cleared by `./dev.sh down -v`).
  SEED_MARKER="${INFINIBAY_BASE_DIR:-/opt/infinibay}/.seeded"
  if [ -f "$SEED_MARKER" ]; then
    log "seed already applied (marker present) — skipping."
  else
    log "seeding database (first run)…"
    if npm run db:seed; then
      touch "$SEED_MARKER" 2>/dev/null || true
    else
      warn "seed skipped/failed (continuing — this is non-fatal)"
    fi
  fi
fi

# ── 4. ensure the filesystem roots the backend expects ───────────────────────
mkdir -p "${INFINIBAY_BASE_DIR:-/opt/infinibay}"/{iso,iso/temp,iso/permanent,wallpapers,sockets,scripts,templates,disks} 2>/dev/null || true

# ── 5. run with hot reload ───────────────────────────────────────────────────
# nodemon adds ./node_modules/.bin to PATH, so `ts-node` is the project's own
# pinned version — identical to `npm start`, just auto-restarting.
log "starting backend with hot reload on :4000 …"
exec nodemon \
  --watch app \
  --watch "$INFZ/dist" \
  --ext ts,js,json \
  --delay 2 \
  --exec "ts-node -r tsconfig-paths/register app/index.ts"

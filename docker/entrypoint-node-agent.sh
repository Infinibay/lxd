#!/usr/bin/env bash
# Compute-node agent dev entrypoint (multi-node). Prepares just enough to run the
# node agent, then `exec`s the command handed in as "$@" (join enrollment OR the
# heartbeat/verb server). This is the NODE counterpart of entrypoint-backend.sh
# and deliberately does LESS: NO postgres wait / migrate / seed — a compute node
# holds no DB connection (its DB reads/writes are proxied to the master over RPC).
#
# ORDER MATTERS: infinization is built BEFORE the backend install. The backend
# declares "@infinibay/infinization": "file:../infinization", and infinization has
# a `prepare` script (`npm run build` → tsc). npm runs that prepare while installing
# the backend's file: dependency, so tsc must already exist in infinization's own
# node_modules — otherwise the backend `npm install` dies with `tsc: not found`
# (exit 127) and ts-node never lands, so even `agent:join` (which imports neither
# infinization nor a DB) cannot start. Mirrors entrypoint-backend.sh steps 1–2.
#
# Idempotent: the node_modules / dist volumes persist, so every step is a no-op on
# later runs. Used by docker-compose.node.yml as the `entrypoint` (CMD is the agent
# command; the enrollment run overrides it with `node -r ts-node/register …
# agent/join.ts`). The agents are invoked via `node -r ts-node/register` rather than
# the node_modules/.bin/ts-node shim, which rootless podman may refuse to exec from
# the volume — so what the run actually needs is ts-node RESOLVABLE, not executable.
set -uo pipefail

log()  { echo -e "\033[1;35m[node-agent]\033[0m $*"; }
warn() { echo -e "\033[1;33m[node-agent]\033[0m $*"; }

INFZ=/workspace/infinization
BE=/workspace/backend
NPM_AGE_FLAG="--minimum-release-age=0" # sanctioned dev override of the .npmrc guardrail

# ── 1. infinization sibling (built FIRST — see ORDER MATTERS above) ───────────
# Idempotency checks look for the BINARY each step produces, not just a non-empty
# node_modules — so a previously ABORTED install (which leaves a partial dir) still
# re-runs and self-heals on the next `./dev.sh join`, instead of being skipped.
if [ -d "$INFZ" ]; then
  cd "$INFZ"
  if [ ! -e node_modules/.bin/tsc ]; then
    log "installing infinization deps (first run / repairing partial install)…"
    npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "infinization npm install reported errors"
  fi
  if [ ! -f dist/index.js ]; then
    log "building infinization (tsc && tsc-alias)…"
    npm run build || warn "infinization build reported errors"
  fi
else
  warn "infinization not found at $INFZ — the backend install and verb server will fail. Re-run ./dev.sh join after it is cloned."
fi

# ── 2. backend deps (ts-node + node-forge for join; everything for heartbeat) ─
# Gate on what the agent invocation actually needs: not just that the .bin/ts-node
# symlink exists, but that `node -r ts-node/register -r tsconfig-paths/register` can
# RESOLVE both hooks. So an aborted/partial install that kept the symlink but lost a
# module still re-installs here (self-heals) instead of failing later with
# `Cannot find module`.
cd "$BE"
if [ ! -e node_modules/.bin/ts-node ] \
   || ! node -e 'require.resolve("ts-node/register"); require.resolve("tsconfig-paths/register")' 2>/dev/null; then
  log "installing backend deps (first run / repairing incomplete install — a few minutes)…"
  npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "backend npm install reported errors"
fi

# The heartbeat/verb path transitively imports @prisma/client; generate it from the
# schema (no DB connection needed) so the import resolves. Harmless for join. Never
# migrate/seed here — the node has no DB.
log "prisma generate (client only — no DB connection)…"
npx prisma generate >/tmp/prisma-gen.log 2>&1 || warn "prisma generate reported errors (see /tmp/prisma-gen.log)"

# infinization storage roots + the cert dir join writes its identity into.
mkdir -p /opt/infinibay/{sockets,disks,pids,certs} 2>/dev/null || true

cd "$BE"
log "starting: $*"
exec "$@"

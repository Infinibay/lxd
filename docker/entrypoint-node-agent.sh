#!/usr/bin/env bash
# Compute-node agent dev entrypoint (multi-node). Prepares just enough to run the
# node agent, then `exec`s the command handed in as "$@" (join enrollment OR the
# heartbeat/verb server). This is the NODE counterpart of entrypoint-backend.sh
# and deliberately does LESS:
#
#   • NO postgres wait / migrate / seed — a compute node holds no DB connection.
#     Its DB reads/writes are proxied to the master over RPC (RpcDatabaseAdapter),
#     so there is nothing local to migrate.
#   • infinization is built ONLY for the heartbeat/verb path. `agent:join` is pure
#     enrollment (keypair + CSR + SAS pairing) and imports neither infinization nor
#     a DB, so we skip the slow tsc build for it and the pairing code prints fast.
#
# Idempotent: the node_modules / dist volumes persist, so every step is a no-op on
# later runs. Used by docker-compose.node.yml as the `entrypoint` (CMD is the agent
# command, overridden to `npm run agent:join` for the enrollment run).
set -uo pipefail

log()  { echo -e "\033[1;35m[node-agent]\033[0m $*"; }
warn() { echo -e "\033[1;33m[node-agent]\033[0m $*"; }

INFZ=/workspace/infinization
BE=/workspace/backend
NPM_AGE_FLAG="--minimum-release-age=0" # sanctioned dev override of the .npmrc guardrail

# infinization + a generated Prisma client are needed only by the heartbeat/verb
# path. The join run (agent:join) needs neither — keep its startup snappy so the
# SAS pairing code appears without a multi-minute tsc build first.
NEED_RUNTIME=1
case "$*" in *agent:join*) NEED_RUNTIME=0 ;; esac

# ── backend deps (ts-node + node-forge for join; everything for heartbeat) ───
cd "$BE"
if [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
  log "installing backend deps (first run — a few minutes)…"
  npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "backend npm install reported errors"
fi

if [ "$NEED_RUNTIME" = 1 ]; then
  # ── infinization sibling (file: dep, imported as COMPILED dist by the agent) ─
  if [ -d "$INFZ" ]; then
    cd "$INFZ"
    if [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
      log "installing infinization deps…"
      npm install $NPM_AGE_FLAG --no-audit --no-fund || warn "infinization npm install reported errors"
    fi
    if [ ! -f dist/index.js ]; then
      log "building infinization (tsc && tsc-alias)…"
      npm run build || warn "infinization build reported errors"
    fi
  else
    warn "infinization not found at $INFZ — the verb server will fail. Re-run ./dev.sh join after it is cloned."
  fi
  # The agent transitively imports @prisma/client; generate it from the schema
  # (no DB connection needed) so the import resolves. Never migrate/seed here.
  cd "$BE"
  log "prisma generate (client only — no DB connection)…"
  npx prisma generate >/tmp/prisma-gen.log 2>&1 || warn "prisma generate reported errors (see /tmp/prisma-gen.log)"
  # infinization storage roots + the cert dir join wrote its identity into.
  mkdir -p /opt/infinibay/{sockets,disks,pids,certs} 2>/dev/null || true
fi

cd "$BE"
log "starting: $*"
exec "$@"

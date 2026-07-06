# Infinibay setup TUI (Phase A bootstrap)

A tiny Node CLI that runs on the first `./dev.sh up`, **before** the stack boots.
It collects the pre-boot configuration (DB, admin, secrets, ports, storage),
writes `../.env.docker`, and appends `SETUP_DONE=1`. `dev.sh` then continues to
`compose up` unchanged. This process **never touches the database** — the backend
container entrypoint runs `prisma migrate deploy` + seed.

See [`../docs/setup-system/01-tui-bootstrap.md`](../docs/setup-system/01-tui-bootstrap.md).

## Run

```bash
cd setup-tui
npm install         # @clack/prompts + pg
npm start           # or: node src/index.js
```

`dev.sh` invokes it automatically (host Node, or an ephemeral `node:20` container
if Node is absent) — you rarely run it by hand.

Flags:
- `--env-file <path>` — target env file (default `../.env.docker`).
- `--reconfigure` — re-run even when `SETUP_DONE=1`; **preserves existing secrets**.
- `--host-ip <ip>` — prefill `HOST_IP` (dev.sh passes its `detect_host_ip`).

## What it writes

Curated ~15–20 user-facing keys (the rest keep safe defaults). Secrets
(`TOKENKEY`, `INFINISERVICE_HMAC_MASTER_SECRET`, managed `POSTGRES_PASSWORD`) are
**generated once and never rewritten** — rotating them invalidates sessions /
breaks every guest agent. On `--reconfigure` a real secret is left untouched.

## Modules

- `src/index.js` — the wizard (welcome → DB → admin → network → storage → runtime → deploy).
- `src/env.js` — idempotent `.env.docker` read/write (append + in-place overwrite).
- `src/secrets.js` — generate-once secrets + placeholder detection.
- `src/db-probe.js` — external-DB connectivity + CREATE-privilege probe (`pg`).
- `src/preflight.js` — KVM/virtualization, disk free space, shared-mount verification.

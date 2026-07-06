# Infinibay First-Run Setup System — Implementation Plan

> **Status:** Approved design, not yet implemented.
> **Audience:** the engineer implementing this (possibly in a fresh session with no prior context).
> **These docs are self-contained.** Every fact needed to implement is either here or in
> [`05-grounding-reference.md`](./05-grounding-reference.md) with `file:symbol` anchors.

## What we are building

A **first-run configuration experience** for Infinibay, split into two halves by the moment the
application stack boots. When an operator runs `./dev.sh up` for the first time, they get a guided
setup instead of a stack that silently comes up with insecure defaults.

The design is a **hybrid**, deliberately chosen (see [Decision log](#decision-log)):

1. **Bootstrap = a terminal UI (TUI)** launched by `dev.sh`, BEFORE the stack boots. It collects
   everything that must exist as environment/secrets for the stack to come up healthily, writes
   `.env.docker`, then runs the stack. See [`01-tui-bootstrap.md`](./01-tui-bootstrap.md).
2. **Onboarding = a Harbor web flow at `/setup`** inside the existing frontend, AFTER the stack is
   up. It handles everything that lives in the database and needs an authenticated, rich UI:
   extra users, group permissions, ISOs, migration-mode info. Gated by a reactivated `setupMode`
   flag and auto-closed when finished. See [`02-setup-onboarding.md`](./02-setup-onboarding.md).

Supporting pieces:
- [`03-storage-provider-scaffolding.md`](./03-storage-provider-scaffolding.md) — a `StorageProvider`
  abstraction so today's "trust-your-word" shared-storage flag can grow into real NFS/Ceph support.
- [`04-security-network.md`](./04-security-network.md) — how "LAN-only" is actually enforced
  (host layer, not an in-app IP check) and why.
- [`05-grounding-reference.md`](./05-grounding-reference.md) — the authoritative map of existing
  code (env vars, seed/RBAC, ISO service, migration, Harbor components, the `setupMode` scaffold)
  so you don't have to re-discover it.

## Why the split — the boot boundary

The web UI *is part of the stack it configures* (chicken-and-egg). Some config must exist **before**
the backend can boot; the rest lives **in the database** and can only be set **after** it is up and
authenticated. That line decides everything, including why the sensitive half is a TUI.

```
                         ./dev.sh up  (first run)
                                │
        ┌───────────────────────┴───────────────────────┐
        │  PHASE A — TUI bootstrap (pre-boot)            │   host terminal, NO network port
        │  • DB: managed (compose pg) OR external pg     │   → LAN-only is free here
        │  • Secrets: TOKENKEY, HMAC master (once!)      │
        │  • Admin: real creds OR "dev mode"             │
        │  • Ports / host binding / storage dirs         │
        │  • Storage backend: local | shared-mount       │
        │  writes .env.docker  ─────────────────────────▶│  then runs `docker/podman compose up`
        └───────────────────────┬───────────────────────┘
                                │  backend entrypoint: prisma migrate deploy + seed
                                │  seed creates admin from env + sets setupCompleted=false
                                ▼
        ┌────────────────────────────────────────────────┐
        │  PHASE B — /setup onboarding (post-boot)        │   frontend :3000, Harbor UI
        │  gated by setupMode (AppSettings.setupCompleted)│   auth-gated + time-boxed
        │  • Force admin password change (if dev mode)    │
        │  • Create extra users + assign permissions      │
        │  • Configure group permissions (PermissionMatrix)│
        │  • Pre-upload / auto-download ISOs              │
        │  • Migration mode screen (cold on / live WIP)   │
        │  completeSetup() → setupCompleted=true → closes │
        └────────────────────────────────────────────────┘
```

| | **Phase A — TUI (pre-boot)** | **Phase B — `/setup` (post-boot)** |
|---|---|---|
| Lives in | `lxd` repo, launched by `dev.sh` | `frontend` repo, route `/setup` |
| Config target | `.env.docker` (file) | PostgreSQL (via GraphQL) |
| UI tech | Node + `@clack/prompts` (TUI) | Harbor components (already wired) |
| Network exposure | none (host terminal) | frontend port, auth+time-boxed |
| Can use Harbor? | No (no stack yet) | Yes (frontend build chain is ready) |

## Repos touched

- **`lxd`** (this repo): the TUI (`setup-tui/`), `dev.sh` integration, `docker-compose*.yml`
  changes (external-DB profile, optional host-IP port binding), `.env.docker.example` additions.
- **`backend`**: reactivate `setupMode`, add setup-state to `AppSettings`, a `setupStatus` query +
  `completeSetup` mutation, the DB-probe and shared-storage-verify helpers, `StorageProvider`
  scaffolding, the ISO download/verify service. Reuse existing RBAC + ISO mutations.
- **`frontend`**: the `/setup` route + step components (Harbor), a redirect-to-setup gate, and
  wiring to the existing generated GraphQL hooks (re-run `codegen` after backend schema changes).
- **`infinization`**: none required for v1 (storage stays path-based). Future Ceph/NFS block
  backends would touch `QemuCommandBuilder`; noted but out of scope now.

## Minimum required to enable "Deploy" (Phase A)

The TUI's Deploy button (which writes `.env.docker` and runs `up`) unlocks once:
- **DB** is decided and, for external DB, the reachability+privilege probe passed (or was explicitly
  overridden with a warning).
- **Admin** is decided (strong creds entered, OR "dev mode" acknowledged).
- **Secrets** were generated (automatic).

Everything else (ports, storage dirs, host binding) has safe defaults and is optional.

## Decision log

1. **Hybrid TUI + `/setup`, not a single webapp.** A standalone Harbor app in `lxd` would require
   replicating the frontend's Tailwind/transpile/framer-motion build (Harbor has no publishable
   `dist`; it is consumed from source only). The rich half runs inside the frontend where that
   wiring already exists; the sensitive half is a TUI with zero network exposure.
2. **LAN-only is enforced at the host/network layer, never with an in-app source-IP check.** Under
   Docker/Podman NAT the container sees the gateway's RFC1918 address, so "allow RFC1918" fails
   open. The TUI removes the exposure entirely for the sensitive half; `/setup` is protected by
   auth + a time-boxed `setupMode`. See [`04-security-network.md`](./04-security-network.md).
3. **Secrets generated once, never rewritten.** Rotating `TOKENKEY` invalidates all sessions;
   rotating `INFINISERVICE_HMAC_MASTER_SECRET` breaks every existing guest agent (per-VM keys are
   derived from it) — the guests reject all commands. The TUI must never clobber a non-placeholder
   secret on re-run.
4. **Shared storage stays a "trust-your-word" flag for v1**, but behind a `StorageProvider`
   abstraction + a real reachability check, so NFS/Ceph can be added later without a rewrite.
   See [`03-storage-provider-scaffolding.md`](./03-storage-provider-scaffolding.md).
5. **DB choice: managed (compose Postgres) vs external Postgres** (host/port/user/pass/dbname,
   PostgreSQL only), with a pre-Deploy connectivity + `CREATE` privilege probe.
6. **Target the `dev.sh` path first** (single file `.env.docker`). The LXD path (`.env` +
   `values.yml`, different key names) is a follow-up.
7. **Live migration option exists on-screen but is disabled** (WIP). Cold is the only runtime
   behavior; the mode selector is informational. See the live-migration gap analysis (separate doc)
   for what "live" would eventually require.

## Implementation order (suggested)

Each phase is independently testable. Do them roughly in this order:

1. **Backend foundation** — `AppSettings` setup-state fields, `setupStatus` query, `completeSetup`
   mutation, reactivate `setupMode` reading the flag, DB-probe + shared-storage-verify helpers,
   `StorageProvider` scaffolding. (`02` + `03`)
2. **TUI** — `setup-tui/` package, `dev.sh` integration, env writing, DB branch + probe, secret
   generation, storage choice. (`01`)
3. **ISO service** — the download/verify orchestrator on top of `ISOService`/`osProfiles`. (`02` §ISOs)
4. **Frontend `/setup`** — route, redirect gate, step components in Harbor, wire to hooks. (`02`)
5. **Security hardening** — optional host-IP port binding + firewall snippet, doc the posture. (`04`)
6. **Point-6 extras** — see checklist in [`05-grounding-reference.md`](./05-grounding-reference.md#point-6-extras-checklist).

## Glossary

- **Managed DB** — PostgreSQL run by the compose stack (`postgres` service).
- **External DB** — a PostgreSQL the operator already runs; we only get a connection string.
- **Dev mode admin** — the seed default `admin@example.com` / `password`; convenient, insecure,
  must force a password change in `/setup`.
- **`setupMode`** — a backend authorization context flag (already scaffolded, currently hardcoded
  `false`) that, when true, exposes first-run resolvers and signals the UI to redirect to `/setup`.
- **StorageProvider** — the new abstraction over disk storage backends (local / shared-mount /
  future ceph).

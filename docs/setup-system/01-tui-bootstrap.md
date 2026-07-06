# 01 — Phase A: TUI Bootstrap (pre-boot)

The terminal UI that runs on the first `./dev.sh up`, collects pre-boot config, writes
`/home/andres/lxd/.env.docker`, then hands control back to `dev.sh` to bring the stack up.

Grounding for every file/symbol named here is in [`05-grounding-reference.md`](./05-grounding-reference.md).

---

## 1. Technology & where it lives

- **Package:** `lxd/setup-tui/` — a small **Node + TypeScript** CLI using
  [`@clack/prompts`](https://github.com/bombshell-dev/clack) (clean multi-step prompts, spinners,
  validation). Alternatives considered: Ink (React-in-terminal — heavier), bash + `gum`/`whiptail`
  (no Node dep but awkward for the pg probe). **Recommendation: `@clack/prompts`.**
- **Dependencies:** `@clack/prompts`, `pg` (for the external-DB probe), and Node's `crypto`
  (secret generation, no openssl dependency). Keep it tiny; commit a `package.json` +
  lockfile in `setup-tui/`.
- **Entry:** `setup-tui/src/index.ts` → build to `setup-tui/dist/` (or run with `tsx`).

### Host Node vs containerized run (decision to finalize)

The host running `dev.sh` has Docker/Podman but may not have Node. Two options:
- **(A) Require Node on host** — simplest; document it as a prerequisite. Most devs have it.
- **(B) Run the TUI in an ephemeral container** —
  `docker run --rm -it -v "$PWD:/work" -w /work node:20 npx tsx setup-tui/src/index.ts`.
  No host Node needed, **and** the external-DB probe then runs from the *same network context the
  backend container will use* (so `host.docker.internal` / gateway reachability is tested honestly).

**Recommendation:** default to (A) for DX; if `node` is absent, fall back to (B) automatically in
`dev.sh`. Whichever runs the probe, see [§4.3](#43-the-reachability--privilege-probe) for the
host-vs-container reachability nuance — surface it to the user.

---

## 2. `dev.sh` integration

The natural seam is **inside `ensure_env()`**, right after it copies `.env.docker.example` and runs
`ensure_master_env`, and **before** it sources the file (`set -a; . "$ENV_FILE"`) and before
`configure_lan_access` / `dc up`. That is exactly where `ensure_master_env` already appends keys, so
a `run_setup_tui` call there is idiomatic.

```sh
# dev.sh, inside ensure_env() after cp example + ensure_master_env, before sourcing:
if setup_needed; then          # true when no SETUP_DONE marker and interactive TTY
  run_setup_tui || die "setup cancelled"
fi
```

- `setup_needed()` — true when `.env.docker` lacks a `SETUP_DONE=1` marker **and** stdin is a TTY.
  (Non-interactive/CI runs skip the TUI and use whatever `.env.docker` holds — preserves current
  behavior.)
- `run_setup_tui()` — runs the Node TUI (host or container per [§1](#host-node-vs-containerized-run-decision-to-finalize)),
  which writes `.env.docker` and, on success, appends `SETUP_DONE=1`.
- Add a `./dev.sh reconfigure` subcommand (and/or `up --reconfigure`) that re-runs the TUI even when
  `SETUP_DONE=1` is present, **preserving existing secrets** (see [§3](#3-secret-generation-rules)).

Everything downstream (`configure_lan_access`, `detect_runtime`, compose `up`, the container-side
`migrate deploy` + seed) then flows **unchanged**. The TUI does **not** run migrations or seed —
`docker/entrypoint-backend.sh` already does (`prisma migrate deploy`, then marker-gated
`npm run db:seed`).

### Idempotent writing

Reuse the semantics of `dev.sh ensure_env_key()` (grep-guarded append: write `KEY=val` only if the
key is absent). For values the user *changes*, the TUI must **update** existing keys (sed-replace),
not just append. Implement a small `writeEnvKey(file, key, value, {overwrite})` in the TUI mirroring
`ensure_env_key` but with overwrite support.

---

## 3. Secret generation rules (critical — read Decision #3 in README)

Generate with Node `crypto.randomBytes(n).toString('base64url')`:

| Var | Length | Rule |
|---|---|---|
| `TOKENKEY` | ≥ 32 (use 40) | **Generate once. Never overwrite a non-placeholder value.** |
| `INFINISERVICE_HMAC_MASTER_SECRET` | 44 | **Generate once. Never overwrite** (per-VM keys derive from it; rotating breaks all guest agents). |
| `INFINIBAY_CLUSTER_TOKEN` | 32 | Only if multi-node chosen; generate once. |
| `POSTGRES_PASSWORD` | 24 | Only for **managed** DB; generate once. Not used for external DB. |

"Placeholder" = empty, `changeme`, or the `dev-insecure-change-me` defaults shipped in
`.env.docker.example`. Detection logic mirrors `setup.sh ensure_secret()`. On `reconfigure`, a real
secret is left untouched and the TUI shows "already generated ✓".

---

## 4. Wizard steps

Order matters only for the "minimum to Deploy" gate (DB + admin + secrets). Present as clack groups.

### 4.1 Welcome

Branding, one-line explanation, and a note that this configures the **dev** stack
(`.env.docker`). Mention the LXD path is separate (follow-up).

### 4.2 Database

A branch (`select`):
- **Managed (recommended)** — compose runs `postgres:16`. Collect (with defaults): `POSTGRES_USER`,
  `POSTGRES_DB`, `POSTGRES_PORT`. Generate `POSTGRES_PASSWORD`. In dev, `DATABASE_URL` is **derived
  in compose** from these → **do not write `DATABASE_URL`**.
- **External PostgreSQL** — collect `host`, `port` (5432), `user`, `password`, `dbname`, and an
  optional `sslmode` (`disable`/`require`). Assemble and write
  `DATABASE_URL=postgresql://user:pass@host:port/dbname?sslmode=...`. **Also disable the compose
  `postgres` service** for this run — use a compose profile (see
  [`04-security-network.md`](./04-security-network.md#compose-changes) / compose notes below), e.g.
  set `COMPOSE_PROFILES` so the `postgres` service (guarded by `profiles: [managed-db]`) is excluded.

**Caveats to display for External DB** (per user request):
- PostgreSQL only (Prisma schema is pg-specific).
- Must be reachable **from inside the backend container** — if the DB is on this host, that's
  `host.docker.internal` (or the host LAN IP), not `localhost`.
- The user needs **CREATE privileges** — first boot runs `prisma migrate deploy` which creates
  ~70 tables in that database.
- Recommend PostgreSQL ≥ 14.
- For remote DBs, prefer `sslmode=require`.

#### 4.3 The reachability & privilege probe

Before enabling Deploy for External DB, run a probe with the `pg` client and show a clear result:

```ts
// pseudocode
const client = new pg.Client({ host, port, user, password, database: dbname, ssl });
await client.connect();                        // → connectivity
await client.query('SELECT 1');                // → auth OK
const { rows } = await client.query(
  "SELECT has_database_privilege(current_user, current_database(), 'CREATE') AS can_create");
// optionally, a real create/drop to be sure:
await client.query('CREATE TEMP TABLE _ib_probe (x int); DROP TABLE _ib_probe;');
```

Report exactly which check failed (DNS/connect refused / auth / no CREATE). **Reachability nuance:**
if the probe runs on the host but the backend runs in a container, a `localhost` DB reachable from
the host may be `host.docker.internal` from the container — warn and, ideally, run the probe in a
container (option B in [§1](#host-node-vs-containerized-run-decision-to-finalize)) so it matches
runtime. Allow the user to **override** a failed probe with an explicit "I understand, continue
anyway" confirmation (they may be configuring a DB that isn't up yet).

### 4.4 Super admin

A branch:
- **Set real credentials** — collect `DEFAULT_ADMIN_EMAIL`, `DEFAULT_ADMIN_PASSWORD` (enforce
  **≥ 12 chars** here; the production seed enforces this too), confirm password. Write them.
- **Development mode** — keep `admin@example.com` / `password`. Show a **prominent warning** that
  this is insecure for production. Write `DEFAULT_ADMIN_EMAIL=admin@example.com`,
  `DEFAULT_ADMIN_PASSWORD=password`, and a marker the seed reads to set
  `AppSettings.devModeAdmin=true` (see [`02`](./02-setup-onboarding.md)) so `/setup` **forces a
  password change**. Simplest marker: an env var `INFINIBAY_DEV_MODE_ADMIN=1` consumed by the seed.

The admin is created by the **seed** from these env vars (idempotent upsert). The TUI does not touch
the DB.

### 4.5 Network & exposure

- `HOST_IP` — prefill from `dev.sh detect_host_ip()`. Used for LAN advertise + CORS.
- `BACKEND_PORT` (4000), `FRONTEND_PORT` (3000), `POSTGRES_PORT` (5432),
  `SPICE_PROXY_PORT_MIN/MAX` (6100–6119) — defaults; let the user change.
- **Optional LAN-only binding** — offer "bind published ports to `${HOST_IP}` / `127.0.0.1`
  instead of `0.0.0.0`" and write a `PORT_BIND` value the compose port mappings use. See
  [`04-security-network.md`](./04-security-network.md). This is the *real* LAN control.
- CORS/advertise vars (`NEXT_PUBLIC_*`, `ALLOWED_ORIGINS`, `APP_HOST`, `GRAPHIC_HOST`,
  `FRONTEND_URL`): either let `configure_lan_access()` derive them (default) or pin overrides.
  **Note:** `dev.sh` recomputes/exports these each run and only overrides values still equal to
  `localhost`/`127.0.0.1`; a pinned literal IP is respected.

### 4.6 Storage

- `INFINIZATION_DISK_DIR` (default `/var/lib/infinization/disks`) — where qcow2 disks live. **Free-
  space check**: stat the path/partition, warn if low.
- `INFINIBAY_BASE_DIR` (default `/opt/infinibay`), and optionally
  `INFINIZATION_SOCKET_DIR`/`PID_DIR`/`BACKUP_DIR`/`GOLDEN_IMAGE_DIR` — advanced, defaults fine.
- **Storage backend** (feeds [`03`](./03-storage-provider-scaffolding.md)):
  - **Local (default)** — per-node disks. Writes nothing special (or `INFINIBAY_STORAGE_BACKEND=local`).
  - **Shared mount** — NFS/iSCSI/SAN mounted at the disk dir. Writes `INFINIBAY_SHARED_STORAGE=true`
    **and** `INFINIBAY_STORAGE_BACKEND=shared-mount`, but **only after** the shared-storage verify
    check (is the disk dir a mountpoint / network fs / writable) passes or is explicitly overridden.
    For single-node dev this option is irrelevant — hide it unless multi-node was chosen.

### 4.7 Runtime toggles & preflight

- `NODE_ENV` (development default), `LOG_LEVEL`, `RUN_SEED` (true first run), `KVM`
  (auto-detected — see preflight), `INFINIZATION_DISABLE_SANDBOX`, `BCRYPT_ROUNDS`.
- **KVM preflight** — check `/dev/kvm` + CPU virt flags; if absent, warn "control-plane-only mode
  (no VM create/start)" and set `KVM` accordingly. (Point-6 extra.)
- Optional: hostname/timezone note, `INFINIZATION_BACKUP_DIR` (point-6 extras).

### 4.8 Review & Deploy

- Render a summary table of every key that will be written (mask secrets, but offer "reveal once so
  you can save them" — especially the admin password and generated secrets).
- **Deploy** enabled per the [minimum gate](./README.md#minimum-required-to-enable-deploy-phase-a).
  On confirm: write all keys to `.env.docker` (idempotent/overwrite), append `SETUP_DONE=1`, exit 0.
  `dev.sh` continues to `up`.

---

## 5. Env-var surface the TUI writes to `.env.docker`

Curated (~15–20 user-facing of ~110 total; the rest keep safe defaults). Full catalog + which are
internal is in [`05-grounding-reference.md`](./05-grounding-reference.md#env-var-catalog).

```
# Database (managed)         POSTGRES_USER, POSTGRES_PASSWORD*, POSTGRES_DB, POSTGRES_PORT
# Database (external)        DATABASE_URL (+ COMPOSE_PROFILES to drop the pg service)
# Secrets (generate once)    TOKENKEY, INFINISERVICE_HMAC_MASTER_SECRET, [INFINIBAY_CLUSTER_TOKEN]
# Admin bootstrap            DEFAULT_ADMIN_EMAIL, DEFAULT_ADMIN_PASSWORD, [DEFAULT_ADMIN_ROLE],
#                            [INFINIBAY_DEV_MODE_ADMIN]
# Ports                      BACKEND_PORT, FRONTEND_PORT, POSTGRES_PORT, SPICE_PROXY_PORT_MIN/MAX
# Network/exposure           HOST_IP, PORT_BIND, [NEXT_PUBLIC_*, ALLOWED_ORIGINS, APP_HOST,
#                            GRAPHIC_HOST, FRONTEND_URL]
# Storage                    INFINIZATION_DISK_DIR, INFINIBAY_BASE_DIR, INFINIBAY_STORAGE_BACKEND,
#                            [INFINIBAY_SHARED_STORAGE]
# Runtime toggles            NODE_ENV, LOG_LEVEL, RUN_SEED, KVM, BCRYPT_ROUNDS,
#                            [INFINIZATION_DISABLE_SANDBOX]
# Marker                     SETUP_DONE=1
```
`*` generated. `[...]` = conditional.

**Do not write** `DATABASE_URL` for managed DB (compose derives it). **Never rewrite** the two
secrets once real.

---

## 6. What Phase A explicitly does NOT do

- No DB migrations / seed (the backend entrypoint does).
- No user/permission/ISO creation (that is Phase B, in-DB).
- No in-app IP filtering (LAN-only is host-layer — see [`04`](./04-security-network.md)).

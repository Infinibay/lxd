# Setup-system — implementation summary

Status of the plan in `01`–`05`. What was built, per repo. Paths relative to each
repo root (`lxd/`, `repos/backend`, `repos/frontend`).

## backend

- **`prisma/schema.prisma`** — `AppSettings` gains `setupCompleted`, `setupPhase`,
  `devModeAdmin`, `setupStartedAt`, `setupCompletedAt`, `storageConfig Json?`.
- **`prisma/migrations/20260705120000_add_setup_state_to_app_settings/`** — adds the
  columns and **backfills existing installs to completed** (only existing installs
  have the AppSettings row at migrate time; fresh installs get it from the seed).
- **`prisma/seed.ts`** — sets `setupCompleted=false` and `devModeAdmin` (true when
  `INFINIBAY_DEV_MODE_ADMIN=1` or the admin password is the dev default) on CREATE only.
- **`app/utils/setupState.ts`** — `isSetupOpen(prisma)` (cached, fail-closed) + `invalidateSetupCache()`.
- **`app/index.ts`** — both GraphQL context builders now set `setupMode: await isSetupOpen(prisma)`
  (was hardcoded `false`).
- **`app/graphql/resolvers/setup/{resolver,type}.ts`** — `SetupStatusType`/`SetupStepType`;
  `setupStatus` query (public, drives the redirect gate), `completeSetup` mutation
  (`@Authorized('ADMIN')`, refuses while dev-default password is in place),
  `setupChangeAdminPassword` mutation (changes the authed admin's password + clears
  `devModeAdmin` atomically).
- **`app/services/storage/`** — `StorageProvider` interface + `Local`/`SharedMount`
  providers + `CephRbd` stub + `verifySharedStorage()` + `getStorageProvider()` /
  `getConfiguredStorageProvider()` factory (DB `storageConfig` → env). Consolidated the
  triplicated `INFINIBAY_SHARED_STORAGE` reads: `VMMigrationService`, `machine/resolver`
  and `production-preflight` now source shared-ness via the provider (preflight also
  runs a real mount `verify()`).
- **`app/services/IsoDownloadService.ts`** — auto-download for Ubuntu/Fedora from the
  published index (`SHA256SUMS`/`CHECKSUM`, no HTML scraping), checksum + content
  validation, lands in the canonical flat `${BASE}/iso/${os}.iso`, registers it, populates
  the `checksum`/`downloadUrl` columns. **Windows is upload-only.** Progress via
  `ISOEventManager` download events. Wired as `startOSIsoDownload` / `autoDownloadableOSes`
  on `ISOResolver`. `osProfiles.ts` grew `autoDownload`/`officialDownloadUrl` metadata;
  the upload-route content validators are now exported for reuse.

## lxd (orchestrator)

- **`setup-tui/`** — Node/`@clack/prompts` Phase A wizard: DB (managed / external + `pg`
  reachability+CREATE probe), generate-once secrets, admin (real / dev-mode marker),
  network + `PORT_BIND`, storage (+ shared-mount verify), KVM/disk preflight, reveal-once
  secrets, review → writes `.env.docker` + `SETUP_DONE=1`. Never touches the DB.
- **`dev.sh`** — `setup_needed()`/`run_setup_tui()` hooked into `ensure_env()` before the
  env file is sourced; `reconfigure` subcommand + `up --reconfigure` (preserves secrets);
  `COMPOSE_PROFILES`/`PORT_BIND` defaults; external-DB override wiring; `dc()` turns
  `COMPOSE_PROFILES` into `--profile` flags (works on docker compose AND podman-compose).
- **compose** — `postgres` behind the `managed-db` profile; `backend.depends_on.postgres`
  is `required:false` (external DB excludes postgres cleanly); all published ports prefixed
  with `${PORT_BIND:-0.0.0.0}`; `docker-compose.external-db.yml` overlays the external DB
  (plain `${VAR}` reads — podman-compose can't nest defaults).
- **`provisioning/setup-firewall-lan-only.sh`** + **`docs/setup-system/SECURITY.md`** — host
  nftables snippet + posture (why app-level IP filtering is not used).

## frontend

- **`src/app/setup/page.jsx`** + **`src/components/setup/IsoStep.jsx`** — Harbor `Wizard`
  flow: admin sign-in → force password change (if dev-mode) → permissions (leave-default) →
  users → ISOs (auto-download Ubuntu/Fedora + upload, Windows upload-only) → migration mode
  (cold enabled / live WIP-disabled) → finish (`completeSetup`).
- **`src/lib/setupOps.js`** — inline `gql` ops (no codegen; keeps `/setup` self-contained
  and doesn't touch the generated hooks surface / `codegen:check`).
- **redirect gate** — `src/middleware.ts` allows `/setup` pre-login; `src/app/layout.js`
  `AppContent` queries `setupStatus`, funnels every route to `/setup` while open and bounces
  `/setup`→app once completed, renders `/setup` chrome-free, and yields the auth/permission
  gates to the setup gate to avoid redirect loops.

## Deviations from the plan (deliberate)

- **ISO progress uses polling (`checkISOStatus`), not a Socket.IO subscription** — the
  realtime socket may be unconnected during `/setup`; polling is bulletproof. The backend
  still emits `iso:download:*` events.
- **Frontend uses inline `gql`, not codegen** — avoids a codegen run and any `schema.graphql`
  mirror drift; `codegen:check` is unaffected.
- **External-DB postgres exclusion uses a compose profile + `required:false` + an override
  file** (verified on podman-compose 1.2.0) rather than nested compose defaults (which
  podman-compose mis-parses).

## Not done (noted for later)

- Department/bridge subnet picker (seed hardcodes `10.10.X.0/24`).
- virtio-win driver prefetch button in `/setup` (backend `setupVirtIODrivers` exists).
- "Re-open setup" admin action (flip `setupCompleted=false`).
- LXD self-hosting path (`.env` + `values.yml`) — dev.sh path targeted first per plan.
- Ceph RBD backend (stub only; needs infinization `QemuCommandBuilder` work).

## Verification status

- lxd: `bash -n dev.sh`, `bash -n` firewall script, `node --check` + import smoke-test of all
  TUI modules (deps installed) — pass. `podman-compose config` validated for managed + external
  + kvm/cluster combinations.
- backend/frontend: authored against verified symbols/APIs; **not** type-checked/built on the
  host (dev deps live in the container volumes). Real build happens in-container via
  `./dev.sh up` (backend runs `prisma generate` + full `tsc` type-checking at boot).
- An adversarial multi-agent review pass over the whole diff found and **fixed 5 issues**:
  (1) a `group()` cancel handler that didn't abort → could write `BACKEND_PORT=canceled`;
  (2) compose not forwarding `INFINIBAY_STORAGE_BACKEND`/`INFINIBAY_SHARED_STORAGE`/`INFINIBAY_DEV_MODE_ADMIN`
  to the backend container (TUI storage/dev-mode selection was dropped);
  (3) the Wizard could skip the step after the password step because the step list was rebuilt
  from a prop that flipped mid-flow (snapshot `devModeAdmin` at mount);
  (4) `statfsSync` named import crashing the TUI on Node 18.0–18.14 (namespace + runtime guard);
  (5) `DATABASE_URL` removed mid-wizard breaking the "cancel writes nothing" invariant (deferred to final write).

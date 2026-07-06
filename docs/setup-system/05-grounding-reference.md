# 05 — Grounding Reference

The authoritative map of existing code the setup system builds on, so a fresh session doesn't
re-research. Paths are relative to each repo root (`repos/backend`, `repos/frontend`,
`repos/infinization`, or the `lxd` repo root). **Line numbers are hints and may drift — trust the
file + symbol names.** Verify on touch.

Repo layout reminder: `lxd/` is the orchestrator (bash+yaml); it clones the 4 app repos into
`lxd/repos/{backend,frontend,infinization,infiniservice}`.

---

## Deploy / env (lxd repo)

| What | Where |
|---|---|
| Dev stack entrypoint | `lxd/dev.sh` — `ensure_env()`, `ensure_env_key()` (idempotent grep-guarded append to `.env.docker`), `ensure_master_env()`, `configure_lan_access()`, `detect_host_ip()`, `detect_public_ip()` |
| Dev config file | `lxd/.env.docker` (copied from `lxd/.env.docker.example` on first `up`) |
| Compose | `lxd/docker-compose.yml` (+ `.kvm.yml`, `.cluster.yml`). Dev builds `DATABASE_URL` inline from `POSTGRES_*` @`postgres:5432`; injects `TOKENKEY`, `INFINISERVICE_HMAC_MASTER_SECRET`, `DEFAULT_ADMIN_*`, `RUN_SEED`, `ALLOW_INSECURE_JWT_FALLBACK=1` |
| Backend container bootstrap | `lxd/docker/entrypoint-backend.sh` — waits for pg, `prisma migrate deploy`, then marker-gated `npm run db:seed` (marker `${INFINIBAY_BASE_DIR}/.seeded` in a persistent volume) |
| LXD path (follow-up) | `lxd/setup.sh` `check_env_file()` + `ensure_secret()` (openssl-rand gen for `DB_PASSWORD`/`ADMIN_PASSWORD`/`TOKENKEY`(40)/`INFINISERVICE_HMAC_MASTER_SECRET`(44)); `lxd/provisioning/backend.sh` writes `/opt/infinibay/backend/.env`; config split across `lxd/.env` + `values.yml` |

Dev defaults are **insecure on purpose**: `TOKENKEY=dev-insecure-change-me`,
`INFINISERVICE_HMAC_MASTER_SECRET=dev-insecure-change-me`, admin password `password`, tolerated by
`NODE_ENV=development` + `ALLOW_INSECURE_JWT_FALLBACK=1`.

### Env var catalog

~110 vars total via `process.env` across `backend/app` + `infinization/src`; infinization subset
documented in `infinization/docs/CONFIGURATION.md` (precedence: typed config > env > default). The
**curated user-facing ~15–20** the TUI writes are listed in
[`01-tui-bootstrap.md`](./01-tui-bootstrap.md#5-env-var-surface-the-tui-writes-to-envdocker).

Key fail-closed behaviors:
- `TOKENKEY` required in prod, ≥32 chars — `backend/app/utils/jwtAuth.ts`.
- `INFINISERVICE_HMAC_MASTER_SECRET` unset → guest agent rejects **all** commands (metrics still
  flow) — `backend/app/services/VirtioSocketWatcherService.ts`. **Never rotate after VMs exist.**

---

## Super admin & RBAC (backend)

| What | Where |
|---|---|
| Admin seed | `backend/prisma/seed.ts` — `createAdminUser()` upserts by email, `bcrypt.hash(pw,10)`. Defaults `DEFAULT_ADMIN_EMAIL=admin@example.com`, `DEFAULT_ADMIN_PASSWORD=password`, `DEFAULT_ADMIN_ROLE=SUPER_ADMIN`. `validateAdminSeedPassword()` THROWS in prod if pw is `password` or <12 chars; warns in dev |
| Role presets | `backend/app/permissions/presets.ts` — `applyRolePresets()`, `ROLE_PRESETS`: `SUPER_ADMIN`=`*`@ANY, `ADMIN`=every `:manage`@ANY except governance (+role:view, audit:view), `USER`=own-scoped desktop+scripts. `resetRoleToPreset()` |
| Permission registry | `backend/app/permissions/registry.ts` — `RESOURCES`, `GROUPS`; vocabulary is `resource:verb`, 26 resources, `<resource>:manage`, cross-resource bundles, `*` |
| Scope enum | `PermissionScope` = OWN\|DEPARTMENT\|ANY (`schema.prisma`, `registry.ts`) |
| Effective grants | `backend/app/permissions/PermissionService.ts` — role grants ∪ ALLOW overrides − DENY; falls back to Role matching legacy `role` enum when `roleId` null |
| Authorization chokepoint | `@Can('resource:verb', {...})` TypeGraphQL middleware |
| User creation | `backend/app/graphql/resolvers/user/resolver.ts` — `createUser` (`@Can('user:create')`), bcrypt(`BCRYPT_ROUNDS`\|\|10), checks pw==confirm + unique email, links roleId. **No min-length check.** Only SUPER_ADMIN mints SUPER_ADMIN |
| Policy mutations | `backend/app/graphql/resolvers/policy/resolver.ts` — `createRole`, `setRolePermission`, `assignUserRole`, `setUserPermissionOverride`, `resetRoleToDefault`, `permissionRegistry` query, `roles`. Anti-escalation via `assertActorCanGrant` (actor grants only what it holds) |
| Data model | `backend/prisma/schema.prisma` — `Role{key,name,isSystem,priority}`, `RolePermission{roleId,permission,scope}`, `UserPermissionOverride{userId,permission,scope,effect}`; `User` has legacy `role` enum AND optional `roleId` |

The seed also runs inside one `$transaction`: Default department (`10.10.X.0/24`), applications,
scripts, a machine-template category, and **`AppSettings` (id `default-settings`)** — extend this row
for setup state (see [`02`](./02-setup-onboarding.md#11-persisted-setup-state)).

---

## `setupMode` scaffold (backend) — reactivate, don't reinvent

| What | Where |
|---|---|
| Context flag | `backend/app/utils/context.ts` — `InfinibayContext.setupMode` |
| Auth check | `backend/app/utils/authChecker.ts` — `checkSetupModeAccess` (grants when `setupMode===true`) |
| Hardcoded false (change these) | `backend/app/index.ts` — both the `/graphql` HTTP mount and the graphql-ws mount set `setupMode: false` |
| Setup resolver + service stubs | `backend/app/graphql/resolvers/setup/resolver.ts`, `backend/app/utils/SetupService/index.ts` — envision hardware/storage detection (btrfs @ `/mnt/storage`), currently TODO/not wired |

No `isConfigured`/first-run flag exists — add `AppSettings.setupCompleted` etc. (See [`02`](./02-setup-onboarding.md).)

---

## ISO management (backend)

| What | Where |
|---|---|
| DB model | `backend/prisma/schema.prisma` — `ISO{filename(unique),os,version,size,checksum,downloadUrl,path,isAvailable,lastVerified}` (`downloadUrl`+`checksum` exist but unused) |
| Service | `backend/app/services/ISOService.ts` — `registerISO`, `syncISOsWithFileSystem` (non-recursive readdir of flat dir), `validateISO` (size only), `calculateChecksum`, `getSystemReadiness`, `checkMultipleOSAvailability` |
| Upload | `backend/app/routes/isoUpload.ts` — `POST /isoUpload` (admin-gated, multer→temp, content-validates Ubuntu via 7z/casper + Fedora via isoinfo, renames to canonical `${os}.iso`) |
| GraphQL | `backend/app/graphql/resolvers/ISOResolver.ts` — `availableISOs`, `checkISOStatus`, `checkSystemReadiness`, `syncISOs`, `registerISO`, `validateISO`, `removeISO` (`@Can('iso:*')`) |
| VM consumption | `backend/app/services/CreateMachineServiceV2.ts` `getOSIsoPath(os)` — reads `INFINIBAY_ISO_DIR ?? ${BASE}/iso` (flat), canonical `${os}.iso` first, else `osProfiles.isoPatterns` glob |
| OS catalog | `backend/app/services/install/osProfiles.ts` — `isoPatterns`, `family`, `expectedEdition`, `mechanism`. Pickable `OsEnum` = `windows10, windows11, ubuntu, fedora` (`machine/type.ts`). (debian + rhel-family modeled for install only, not pickable) |
| Dormant auto-download | `backend/scripts/install.ts` — `downloadUbuntu()`/`downloadFedora()` (HTML-scrape latest, **commented out**), download into `iso/permanent/{os}/` (NOT scanned by the live flat-dir path). `setupVirtIODrivers()` runs (virtio-win). `backend/scripts/download-windows-v2.ts` uses expiring MS CDN links |
| ISO dirs | `INFINIBAY_BASE_DIR` (root, default `/opt/infinibay`), `INFINIBAY_ISO_DIR` (override), `INFINIBAY_ISO_PERMANENT_DIR`, `INFINIBAY_ISO_TEMP_DIR` |

Build the new `IsoDownloadService` on top of these — see
[`02` §4](./02-setup-onboarding.md#4-iso-download--verify-service). Land downloads in the **flat**
`${BASE}/iso/${os}.iso`. Windows = upload/manual only.

---

## Storage & migration (backend + infinization)

| What | Where |
|---|---|
| Disk dir | `INFINIZATION_DISK_DIR` (default `/var/lib/infinization/disks`), read in `backend/app/services/InfinizationService.ts` + ~6 others; assumed identical path on every node |
| Shared-storage flag | `INFINIBAY_SHARED_STORAGE` (`1`/`true`/`yes`) — read ONLY at migration time (`backend/app/graphql/resolvers/machine/resolver.ts`, `backend/app/services/node/VMMigrationService.ts`); NOT read by infinization; honor-system (no mount verification) |
| Migration (cold only) | `VMMigrationService.migrateStoppedMachineToNode` — `MIGRATABLE_STATUSES=['off','stopped','error']`, refuses if qemu alive; accepts `storageMode:'shared'|'external'` override. `AgentStorageMigrationAdapter` copies+sha256-verifies qcow2 over mTLS when not shared |
| Migration trigger | `migrateMachineToNode` mutation (`@Can('vm:migrate')`), `machine/resolver.ts` |
| Preflight | `backend/scripts/production-preflight.ts` — asserts `INFINIBAY_SHARED_STORAGE=true` for cross-node cold migration |
| CPU model (why cold tolerates heterogeneous HW) | `infinization/src/core/QemuCommandBuilder.ts` `setCpu` defaults to `-cpu host`; machine type is bare `'q35'|'pc'` (`infinization/src/types/qemu.types.ts`), default `q35` (`infinization/src/types/config.types.ts`) |
| Cluster env (opt-in) | `INFINIBAY_NODE_ROLE`, `INFINIBAY_CLUSTER_TOKEN`, `INFINIBAY_CLUSTER_MTLS=1`, `INFINIBAY_CLUSTER_PORT`(4433), `INFINIBAY_AGENT_PORT`(9443), `MASTER_CLUSTER_URL`, `INFINIBAY_MASTER_CN` (documented in `backend/.env.example`) |

See [`03-storage-provider-scaffolding.md`](./03-storage-provider-scaffolding.md) for the abstraction.
Live migration is unimplemented — see the separate live-migration gap analysis.

---

## Harbor component map (frontend)

Harbor `@infinibay/harbor` v0.6.0 at `repos/frontend/harbor/src/components`. **Consumed from source
only** — `harbor/dist` is empty, cannot `npm install`; the frontend aliases `@infinibay/harbor*` →
`harbor/src` in `frontend/next.config.js` (+ `transpilePackages`, Tailwind preset, `vitest.config.ts`).
Peer deps: react 18/19, react-dom, framer-motion ≥11. Components render from `harbor/src/index.css`
`:root` token defaults; `HarborProvider` only adds theme switching. **This is why `/setup` lives
inside the frontend, not a standalone app.**

| Need | Component (path under `harbor/src/components/`) |
|---|---|
| Multi-step controller | `inputs/Wizard.tsx` (per-step async `validate()` + `onComplete`) |
| Step progress rail | `navigation/Stepper.tsx` |
| Form primitives | `inputs/{TextField,Textarea,Select,MultiSelect,Combobox,Radio,Checkbox,Switch,NumberField,FormField,FormSection,Form}.tsx` |
| Password UX | `inputs/SecretsInput.tsx` (masked show/hide) + `inputs/PasswordStrength.tsx` (meter). No combined component — compose them |
| Modal (permissions explainer) | `overlays/Dialog.tsx` (or `Drawer.tsx`); also `Popover`, `Tooltip` |
| Warning banners | `feedback/{Alert,Banner,Callout}.tsx` |
| ISO upload | `inputs/FileDrop.tsx` (`onFiles(File[])`, `accept`, `multiple`) |
| Progress | `display/{Progress,ProgressRing,Spinner}.tsx`, `feedback/LoadingOverlay.tsx` |
| Users list / permissions grid | `data/DataTable.tsx`, `data/PermissionMatrix.tsx`, `data/VirtualList.tsx` |
| Migration mode selector | `navigation/SegmentedControl.tsx` or `inputs/Radio.tsx` |
| Scaffolding | `layout/{Card,Container,Page,PageHeader}.tsx`, `sections/Section.tsx` |
| Buttons | `buttons/{Button,ButtonGroup}.tsx` |
| Badges/labels | `display/{Badge,Tag,RoleBadge,StatusDot}.tsx` |

Note: Harbor's own `Toast` is deprecated in the app (migrated to Sonner) — prefer `Alert`/`Callout`
or the app's Sonner. Frontend generated files (`src/gql/hooks.ts`, `graphql.ts`, `gql.ts`) are
codegen output — edit `.graphql` and run `npm run codegen` (CI enforces `codegen:check`).

---

## Network & exposure

| What | Where |
|---|---|
| Backend bind | `backend/app/index.ts` — `httpServer.listen({host:'0.0.0.0'})` (hardcoded). No `trust proxy` anywhere. No helmet |
| CORS | `backend/app/config/server.ts` `buildCorsOptions` — Origin allowlist (`ALLOWED_ORIGINS`), browser-only, NOT a source-IP control |
| Rate limiter (pattern) | `backend/app/config/server.ts` `createRateLimiter` (keys on `req.ip`, mounted only if `RATE_LIMIT_ENABLED==='1'`) — same NAT caveat |
| Frontend bind | `frontend/package.json` scripts `-H ::` (all interfaces); `frontend/src/middleware.ts` cookie-presence gate only |
| Compose ports | published with no host-IP prefix → `0.0.0.0`: backend 4000, frontend 3000, postgres 5432, SPICE 6100–6119 |

The Docker/Podman source-IP gotcha and the correct host-layer enforcement are in
[`04-security-network.md`](./04-security-network.md).

---

## Point-6 extras checklist

Extra first-run configs agreed beyond the original ask:

- [ ] **Forced admin password change** in `/setup` if dev-mode admin was used (`devModeAdmin` flag).
- [ ] **KVM/virtualization preflight** — `/dev/kvm` + CPU virt flags; warn "control-plane-only" if absent; set `KVM`.
- [ ] **Default bridge / department subnet** — seed uses `10.10.X.0/24`; let the operator pick to avoid LAN collisions.
- [ ] **Disk free-space check** on `INFINIZATION_DISK_DIR` before enabling Deploy.
- [ ] **virtio-win drivers** prefetch (needed for Windows guests; `setupVirtIODrivers` exists).
- [ ] **Backup dir** `INFINIZATION_BACKUP_DIR`.
- [ ] **TLS/HTTPS warning** — everything is plain HTTP; warn for beyond-LAN exposure.
- [ ] **Hostname / timezone / locale** note for the appliance.
- [ ] **Review step** showing all env keys to be written, secrets revealable **once** to save.
- [ ] **External-DB reachability + CREATE-privilege probe** (see [`01` §4.3](./01-tui-bootstrap.md#43-the-reachability--privilege-probe)).
- [ ] **Shared-storage mount verification** before writing `INFINIBAY_SHARED_STORAGE=true` (see [`03`](./03-storage-provider-scaffolding.md)).

---

## Open decisions to finalize at implementation time

1. **TUI runtime:** host Node vs auto-fallback to a `node:20` container (the latter also makes the
   DB probe match the backend's network view). See [`01` §1](./01-tui-bootstrap.md#1-technology--where-it-lives).
2. **Dev-mode marker:** `INFINIBAY_DEV_MODE_ADMIN=1` env consumed by the seed, vs the seed comparing
   the password to `'password'`. (Env is explicit; recommended.)
3. **Record migration-mode intent?** Store a UI-only `AppSettings` pref or skip (zero runtime effect
   today). Recommend skip for v1, keep the screen informational.
4. **Re-run Phase B** ("re-open setup" admin action) — out of scope v1; note the hook
   (`setupCompleted=false`).
5. **Compose profile name** for excluding managed postgres (`managed-db`?) and exact `PORT_BIND`
   syntax verified against both Docker and Podman compose in this repo.

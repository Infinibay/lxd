# 02 — Phase B: `/setup` Onboarding (post-boot)

The Harbor-based web flow that runs **after** the stack is up, inside the existing frontend, gated
by a reactivated `setupMode`. Handles everything that lives in the database.

Grounding (file/symbol anchors) is in [`05-grounding-reference.md`](./05-grounding-reference.md).

---

## 1. The `setupMode` contract (the crux)

There is already a **scaffolded but inert** setup gate in the backend. Reactivate it instead of
inventing a new auth path:
- `InfinibayContext.setupMode` (`backend/app/utils/context.ts`) — a context flag.
- `authChecker.checkSetupModeAccess` (`backend/app/utils/authChecker.ts`) — grants access when
  `context.setupMode === true`.
- Both GraphQL context builders currently **hardcode `setupMode: false`**
  (`backend/app/index.ts`, the `/graphql` HTTP mount and the graphql-ws mount).
- A `setup/resolver.ts` + `SetupService` exist with hardware/storage detection stubs (TODO).

### 1.1 Persisted setup state

There is **no** "is configured?" flag today. Add one to the existing **`AppSettings`** row
(`schema.prisma`, singleton id `default-settings`, already seeded). New fields:

```prisma
// AppSettings additions
setupCompleted   Boolean   @default(false)
setupPhase       String    @default("pending")   // pending | in_progress | completed
devModeAdmin     Boolean   @default(false)        // dev-mode admin used → force pw change
setupStartedAt   DateTime?
setupCompletedAt DateTime?
```

- **Seed** (`prisma/seed.ts`) sets `setupCompleted=false` on first run, and `devModeAdmin=true` iff
  the admin was created with the dev default (detect via `INFINIBAY_DEV_MODE_ADMIN=1` env from the
  TUI, or by comparing the seed password to `'password'`).
- A migration must add these columns; existing installs backfill `setupCompleted=true` (they're
  already past setup) — see [§6](#6-idempotency--already-configured-systems).

### 1.2 Gate wiring

- **Backend:** replace the hardcoded `setupMode: false` in both context builders with
  `setupMode: await isSetupOpen()`, where `isSetupOpen()` reads `AppSettings.setupCompleted === false`
  (cache it; refresh on `completeSetup`). While open, `checkSetupModeAccess` lets the setup
  resolvers through **without** a normal privileged session, so the very first admin can drive it.
  > Security note: keep the *scope* of what `setupMode` unlocks minimal — only the setup resolvers,
  > never the whole schema. And it is **time-boxed**: it closes forever after `completeSetup`.
- **Frontend:** a `setupStatus` query drives a redirect. Add a check in the app shell / a light
  middleware: if `setupCompleted === false`, redirect any route to `/setup`; if `true`, `/setup`
  redirects to the app. This is the "auto-close" — once completed, `/setup` is unreachable.

### 1.3 New backend GraphQL surface (thin — reuse everything else)

- `query setupStatus: SetupStatus` — `{ completed, phase, devModeAdmin, steps: [...] }`. Reachable
  while setup is open (and read-only afterwards for the redirect logic).
- `mutation completeSetup: SetupStatus` — validates the minimum (admin has a non-dev password,
  required steps done), sets `setupCompleted=true`, `setupPhase='completed'`, closes `setupMode`.
- Everything else reuses existing mutations (see [§3](#3-steps--harbor-components)). **Re-sync the
  frontend `schema.graphql` mirror and run `npm run codegen`** after these schema changes (CI
  enforces `codegen:check`).

---

## 2. Frontend route & architecture

- Route: `frontend/src/app/setup/` (App Router). It renders inside the existing providers
  (ApolloProvider, Redux, Harbor theme) — so Harbor + generated hooks work with zero extra wiring.
- **Do not** build a standalone app. Harbor is consumed from source via the frontend's
  `next.config.js` aliases + `transpilePackages` + Tailwind preset; a separate app would have to
  replicate all of that. (This is the whole reason Phase B lives here — see README Decision #1.)
- Use the Harbor **`Wizard`** (`harbor/src/components/inputs/Wizard.tsx`) as the step controller —
  it takes `steps[]` with per-step async `validate()` gating Next, plus `onComplete`. Or `Stepper`
  (`harbor/src/components/navigation/Stepper.tsx`) + your own switch if you want more layout control.

---

## 3. Steps & Harbor components

**Always check Harbor first — nearly everything needed already exists.** Component inventory with
paths is in [`05-grounding-reference.md`](./05-grounding-reference.md#harbor-component-map).

### Step 0 — Force admin password change (conditional)

Shown first iff `setupStatus.devModeAdmin === true`. Blocks the rest until changed.
- Components: `SecretsInput` (masked show/hide) + `PasswordStrength` (meter) + `Callout` (the
  "dev mode is insecure" warning) + `Button`.
- Backend: reuse the existing change-password / update-user mutation (see grounding). Clear
  `devModeAdmin=false` on success.

### Step 1 — Group permissions (with "leave default" + explainer modal)

- Render the current roles + the permission catalog from the existing `permissionRegistry` query
  (resources × verbs + groups) and `roles` query. The 3 seeded roles are `SUPER_ADMIN` (`*`),
  `ADMIN` (all `:manage` except governance), `USER` (own-scoped desktop+scripts) from `presets.ts`.
- "Leave default" is the primary path — a `Callout`/`Card` summarizing each role, with a
  **`Dialog`** ("explain default permissions") rendering the preset grants. Offer "reset to default"
  via the existing `resetRoleToDefault` mutation.
- To customize: `PermissionMatrix` (`harbor/src/components/data/PermissionMatrix.tsx`) wired to
  `createRole` / `setRolePermission`. **Anti-escalation is enforced server-side** (`assertActorCanGrant`)
  — the actor can only grant what it holds; surface clear errors.

### Step 2 — Create users

- `DataTable` (or `VirtualList`) listing users; a `Dialog`/form to add one.
- Fields: email, first/last name, password (`SecretsInput` + `PasswordStrength`), role
  (`Select` from `roles`). **Enforce a min length in the UI** — the `createUser` mutation does *not*
  validate password length (only match + uniqueness).
- Backend: reuse `createUser` (bcrypt, uniqueness, roleId linkage, emits real-time events) and
  `assignUserRole` / `setUserPermissionOverride` for per-user grants. Only `SUPER_ADMIN` can mint
  `SUPER_ADMIN`.

### Step 3 — ISOs (pre-upload / auto-download)

- Show present vs missing OSes from the existing `checkSystemReadiness` / `availableISOs` queries.
  Pickable OSes: `windows10`, `windows11`, `ubuntu`, `fedora` (the `OsEnum`).
- **Auto-download (Ubuntu/Fedora):** a **new backend service** on top of `ISOService` +
  `osProfiles` (see [§4](#4-iso-download--verify-service)). UI: `Button` "auto-download latest" per
  OS + `Progress`/`ProgressRing` fed by Socket.IO progress events.
- **Manual (all, required for Windows):** `FileDrop` (`harbor/src/components/inputs/FileDrop.tsx`)
  → existing `POST /isoUpload` (admin-gated, content-validated, renamed to canonical `${os}.iso`).
- On failure of auto-download, show the **official download links** (Ubuntu releases, Fedora
  getfedora, Microsoft) and fall back to `FileDrop`.
- Optional: offer **virtio-win** driver prefetch (needed for Windows guests; `setupVirtIODrivers`
  already implements the download).

### Step 4 — Migration mode (informational; live disabled)

- A `SegmentedControl` or `RadioGroup` with **Cold (enabled, default)** and **Live (disabled,
  "WIP / coming soon")** + a `Tooltip`/`Callout` explaining the trade-off.
- **The user cannot switch to live** — there is no backend for it (cold-only today; see the
  live-migration gap doc). This step is informational; if you want to record intent, store a
  UI-only preference in `AppSettings`, but note it has zero runtime effect now.
- Suggested copy (accurate, non-expert):
  > *Cold migration moves a VM between hosts while it is powered off. Simple and robust — it works
  > even across hosts with different CPUs/hardware, because the VM boots fresh on the target. With
  > shared storage the move is near-instant; without it, Infinibay copies and verifies the disk
  > first. Live migration (no downtime) needs compatible CPUs/machine types + shared-or-mirrored
  > storage + a fast host-to-host link, and is not yet available in Infinibay.*

### Step 5 — Review & finish

- Summary (`DataTable`/`Card`) of what was configured. **Finish** calls `completeSetup` →
  `setupCompleted=true` → `setupMode` closes → redirect into the app.

---

## 4. ISO download & verify service (new backend service)

Build a thin orchestrator on top of the **existing** machinery — do **not** add a new storage/DB path.

- New service, e.g. `backend/app/services/IsoDownloadService.ts`. Given an `OsEnum`:
  1. Resolve the latest official ISO URL + expected checksum (move Ubuntu/Fedora logic out of the
     dormant `scripts/install.ts` `downloadUbuntu()`/`downloadFedora()`; **replace HTML scraping**
     with the published index + `SHA256SUMS`/`CHECKSUM` files; enforce `osProfiles.expectedEdition`
     and kickstart-capable images — Server/Everything netinst, **not** Live).
  2. Stream to a temp file with progress emitted over **Socket.IO** (mirror the existing real-time
     event pattern; add a `migration`-style `iso` resource) — support cancel; ideally resumable.
  3. Verify against the official checksum (populate the `ISO.checksum` + `ISO.downloadUrl` columns
     that already exist but are unused).
  4. Run the existing content validators (`validateUbuntuDesktopISO` 7z / `validateFedoraNetinstallISO`
     isoinfo / `classifyUbuntuEdition`).
  5. Rename into the **flat** dir as `${INFINIBAY_BASE_DIR}/iso/${os}.iso` (the canonical name
     `getOSIsoPath` expects) and call `ISOService.registerISO()`.
- **Gotchas (from research):**
  - Managed ISOs live in a **flat** `${BASE}/iso` as `${os}.iso`; the old `scripts/install.ts`
    downloads into `iso/permanent/{os}/` which the live scanner ignores. **Land downloads in the
    flat dir** or teach `syncISOsWithFileSystem`/`getOSIsoPath` to recurse.
  - **Windows cannot be reliably auto-downloaded** (expiring MS CDN links) → upload/manual only.
  - Add per-OS **download-source + checksum-URL metadata** to `osProfiles.ts` (the catalog is
    designed to grow by data change).
  - No locking today — guard concurrent downloads; a failed partial write to `${os}.iso` could
    shadow a good ISO (canonical-first rule).

---

## 5. Reused backend mutations/queries (no new code)

| Purpose | Existing GraphQL | Guard |
|---|---|---|
| Create user | `createUser` | `@Can('user:create')` |
| Assign role / override | `assignUserRole`, `setUserPermissionOverride` | policy resolver |
| Custom roles | `createRole`, `setRolePermission` | anti-escalation |
| Read catalog | `permissionRegistry`, `roles` | — |
| Reset role | `resetRoleToDefault` | policy resolver |
| ISO status | `availableISOs`, `checkISOStatus`, `checkSystemReadiness` | `@Can('iso:*')` |
| ISO register/upload | `registerISO`, `POST /isoUpload` | admin |

While `setupMode` is open, these run as the first admin (who logs in immediately after seed with
the creds from Phase A). After `completeSetup`, they require normal auth.

---

## 6. Idempotency & already-configured systems

- The migration that adds `setupCompleted` must **backfill existing installs to `true`** (they've
  already run) so upgrades don't suddenly show `/setup`.
- Fresh installs: seed sets `false`.
- Re-running `dev.sh up` after completion: `setupCompleted=true` → `/setup` closed, TUI skipped
  (SETUP_DONE marker). `./dev.sh reconfigure` re-opens the TUI (Phase A) but must not reset DB state
  or rotate secrets. Re-opening Phase B would require an explicit admin action (a "re-run setup"
  button flipping `setupCompleted=false`) — out of scope for v1 but noted.

---

## 7. Frontend deliverables checklist

- [ ] `frontend/src/app/setup/` route + step components (Harbor).
- [ ] Redirect gate (app shell or middleware) keyed on `setupStatus`.
- [ ] `.graphql` operations for `setupStatus`, `completeSetup` + reuse of existing user/permission/ISO
      ops; re-run `npm run codegen`.
- [ ] Socket.IO subscription for ISO download progress (via `realTimeReduxService`).
- [ ] No Dockerfile change expected (route lives in the existing frontend build). Confirm the
      `/setup` path isn't blocked by the existing `middleware.ts` session-cookie gate — it must be
      reachable pre-login while setup is open.

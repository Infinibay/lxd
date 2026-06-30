## VM Migration — Cold & Live

Scope: moving a VM's disk + (for live) its running CPU/RAM state between two Node Agents under master orchestration. Builds on `VMMigrationService.ts` (the existing cold seam, `:4-11,35-113,115-131`), and adds the QEMU primitives infinization lacks today (`QMPClient` has no `migrate*`/`query-migrate`/`migrate_cancel`; `QemuCommandBuilder` has no `-incoming`). Depends on — and does not redesign — the **Node Agent RPC** (transport, mTLS, `prepareIncoming`/`exportDisk`/`importDisk`), **NodeDispatcher** (routing `machineId → nodeId → agent`), **G0 node-scoping**, and the **master-side reconciler**. It assumes `MigrationJob` and the `Node`/`Machine` columns from §2 of the plan.

### 1. Authority model & invariants

The master is the **sole migration coordinator** *and the sole writer of `Machine.status`/`Machine.nodeId` for any machine with a non-null `migrationJobId`*. Agents are dumb executors that expose idempotent verbs. Hard invariants enforced at every phase:

- **I1 — Single-writer:** exactly one node may have a *running* QEMU bound to a VM's disks at any instant. `file.locking=on` (already set, `QemuCommandBuilder.ts:232`) is the last-line backstop; the state machine is the primary guard.
- **I2 — No premature delete:** source disk/process is never destroyed until the target is confirmed authoritative (checksum match for cold-copy; `cont` succeeded + migration `completed` for live).
- **I3 — DB lags reality safely, and the flip is version-CAS'd:** `Machine.nodeId` is flipped only at the atomic switchover point, inside the same transaction that sets the terminal `MigrationJob.phase`. The flip is a **logical state change and MUST bump `Machine.version`**, executed through the existing optimistic-lock path (`PrismaAdapter.transitionVMStatus` / version CAS, `infinization/src/db/PrismaAdapter.ts:699-814`), never a bare `update`. This makes the version bump + `expectVersion` the **primary** stale-command guard (a `Start` enqueued against the pre-migration node fails the CAS and is rejected as stale); the agent's `Machine.nodeId===self` assertion is the **backstop**, not the primary. A crash before this TX ⇒ VM still belongs to source.
- **I4 — Fencing token:** every migration carries a `MigrationJob.id` (epoch) recorded as `Machine.migrationJobId`. An agent rejects any migration verb whose job id ≠ the one the master currently records as active, killing split-brain from retried RPCs. While `migrationJobId` is non-null, the VM is **fenced**: the master's generic heartbeat drift-corrector MUST skip status reconciliation for it (§7).
- **I5 — Mid-migration ownership is the job, not the node:** a VM in flight is owned by its `MigrationJob`, not by either node's node-scoped reaper. Both agents' reconcilers are MigrationJob-aware (§7) so the incoming/paused QEMU is never orphaned or cross-killed.

**HMAC secrets (security cross-reference).** Migration does **not** require `INFINISERVICE_HMAC_MASTER_SECRET` on any compute node. The master derives `HMAC(master, vmId)` and ships only that **per-VM key** over the authenticated RPC to the node(s) currently hosting the VM, and — at migration — JIT to the destination as part of `prepareIncoming` (§5). The master secret never lands on a node; this preserves the blast-radius property (a compromised node forges only for its own VMs). Key custody, rotation, and the corrected secrets-at-rest table are owned by **Security-RBAC §1/§4** (this section flags the contradiction and adopts the Deployment-Installer §8 model as canonical).

### 2. MigrationJob state machine

```
                 ┌──────────── migrate_cancel / timeout / precheck-fail (PRE-PIVOT only) ────────────┐
                 │                                                                                    ▼
 queued ─▶ prechecking ─▶ preparing ─▶ copying ─▶ activating ─▶ pivoted ─▶ switching ─▶ completed
   │          (CPU/cap/   (target      (drive-    (RAM         (mirror     (cont tgt,    (teardown
   │           storage)    -incoming    mirror/    converge,    block-job   flip nodeId   source)
   │                       +disk/net)   precopy)   pre-switch)  -complete)  +version,TX)
   ▼
 failed ─┐                                  pivoted ─▶ (no rollback) ─▶ finish-forward to target
   │     │
   └─▶ rolled_back  (source still authoritative & running; target artifacts reaped) — ONLY pre-pivot
```

`pivoted` is the load-bearing addition: it is persisted **before** the first `block-job-complete` is issued (non-shared/drive-mirror live only) and marks the point past which the source's local qcow2 is no longer authoritative. After `pivoted`, **rollback-to-source is forbidden**; the only safe resolution is finish-forward (cont target, kill source). For `cold-*` and `cold-shared`/shared-storage live there is no mirror, so `pivoted` is skipped and rollback is legal up to `switching`.

`phase` strings persist as the Prisma enum-as-string in the plan: `queued|prechecking|preparing|copying|activating|pivoted|switching|completed|failed|rolled_back`. Terminal: `completed|failed|rolled_back`. Every transition is persisted before the side-effecting RPC, so a coordinator crash is recoverable by reading `phase` (§7).

```ts
type MigrationMode = 'cold-shared' | 'cold-copy' | 'live'
type MigrationPhase =
  | 'queued' | 'prechecking' | 'preparing' | 'copying'
  | 'activating' | 'pivoted' | 'switching' | 'completed' | 'failed' | 'rolled_back'

interface MigrationPlan {
  jobId: string
  machineId: string
  sourceNodeId: string | null   // null = unassigned/new placement
  targetNodeId: string
  mode: MigrationMode
  sharedStorage: boolean
  diskPaths: string[]
  spec: VmLaunchSpec            // full infinization launch spec, §5
  liveParams?: LiveTuning
  perVmHmacKey: string          // HMAC(master, vmId), shipped JIT — never the master secret
}

// Per-disk mirror state, persisted on the job so reconcile can decide pre/post-pivot per disk.
interface DiskMirrorState { device: string; job: 'mir-'+string; pivoted: boolean }
```

### 3. Cold migration — completing the `VMStorageMigrationAdapter` seam

`VMMigrationService.migrateStoppedMachineToNode` (`:35-113`) already validates status (`MIGRATABLE_STATUSES`, `:26`), capacity (`:91-93`), maintenance/staleness, then calls `prepareStorageForMigration` (`:95-100`) and flips `nodeId` (`:102-105`). We implement the injected `storageAdapter` (`:121-124`); the seam is wired and the service signature is unchanged — **except** the `nodeId` flip must route through the version-CAS path (I3).

**`cold-shared`** (`isSharedStorageEnabled()`, `:133-137` true): the adapter only *verifies* the target node mounts the same backing store (agent `statPath(diskPaths)`), then returns. Zero copy.

**`cold-copy`** (local storage): the adapter drives a pull-style stream, checksum-gated, no source delete until confirmed (I2).

```ts
class StreamingStorageMigrationAdapter implements VMStorageMigrationAdapter {
  async prepareMachineStorage(p: PrepareParams): Promise<void> {
    const job = await this.jobs.transition(p, 'copying')
    const src = this.dispatcher.agent(p.sourceNodeId)   // throws if offline
    const dst = this.dispatcher.agent(p.targetNodeId)
    for (const disk of p.diskPaths) {
      const { handle, size, sha256 } = await src.exportDisk({ jobId: p.jobId, path: disk })
      await this.jobs.setBytesTotal(p.jobId, size)
      // target pulls bytes through the AUTHENTICATED peer channel (§3.1), chunked,
      // bytesDone -> MigrationJob.progress (resumable cursor = (handle, offset))
      const got = await dst.importDisk({
        jobId: p.jobId, fromNode: p.sourceNodeId, handle, destPath: disk, size,
        peerToken: p.peerToken,                 // short-lived, job-scoped (§3.1)
        onProgress: b => this.jobs.setBytesDone(p.jobId, b)
      })
      if (got.sha256 !== sha256)                // fail-closed integrity gate (I2)
        throw new MigrationError('checksum-mismatch', { disk, expected: sha256, got: got.sha256 })
    }
    // caller flips nodeId via version-CAS. Source disk reaped ONLY after a confirmed
    // target start() (post-switch GC, §7), never here.
  }
}
```

Decision: **target pulls** (ADR-3) — backpressure throttles to the slower of {target write, network}; `bytesDone` is the resumable cursor.

#### 3.1 Peer data channel — authentication & confidentiality (was unspecified)

The previous draft hand-waved "reuses the agent's mTLS socket," but node certs are issued **`clientAuth` EKU only** (Onboarding §1/§7), so an agent cannot be a TLS *server* to a peer. Raw NBD has no auth. We resolve this explicitly with **option (a) as the v1 default** and (b) as a perf-tier opt-in:

- **(a) Master-proxied (default).** Cross-node disk/NBD bytes flow **through the master** over the two existing master↔agent mTLS legs: source `exportDisk` streams up to the master, master streams down to target `importDisk`. No direct agent↔agent socket exists; no PKI change; confidentiality + peer auth are inherited from the management mTLS. Cost: double LAN hop through the master NIC. Acceptable for VDI overlays and bounded by the §3.2 scheduler's bandwidth budget.
- **(b) Direct peer TLS (opt-in for large fleets).** Issue node certs with **both `clientAuth` and `serverAuth`** (PKI change owned by **Onboarding**), require **mutual TLS + cert-pinning** on the peer channel, and have the master hand each side a **short-lived, job-scoped `peerToken` bound to `MigrationJob.id`** (the I4 fence). For live migration the QEMU `migrate`/NBD stream runs **inside that TLS tunnel** (`tcp:` URI pointed at a local stunnel/`tls-creds` endpoint), bound to the management/overlay plane, **never a routable interface**. SHA-256 (Storage §7) remains the end-to-end integrity gate; it does not replace channel auth.

ADR-4 records the choice. Either way the channel is authenticated and encrypted; bytes are never cleartext on the LAN.

#### 3.2 Migration scheduler & concurrency control (was missing)

A maintenance drain or node-death evacuation can enumerate ~50 VMs; firing all migrations at once saturates NICs/disks and N concurrent `auto-converge` jobs throttle many guests simultaneously. `LiveTuning.maxBandwidthBytes` is per-job and does not bound the aggregate. We add a **master-side migration scheduler** with admission control:

```ts
interface MigrationLimits {
  perSourceNode: number     // e.g. 2 concurrent outbound
  perTargetNode: number     // e.g. 2 concurrent inbound
  clusterWide: number       // e.g. 8 cluster total
  nodeBandwidthBudgetBytes: number  // aggregate cap per node; divided across that
                                    // node's in-flight jobs -> each job's effective
                                    // migrate-set-parameters max-bandwidth
}
```

Drains/evacuations **enqueue** `MigrationJob`s (largest-first ordering, already specified) at `queued` and the scheduler **admits** them only when source/target/cluster slots and bandwidth budget allow; otherwise they wait. On admission the scheduler computes each job's `max-bandwidth = nodeBandwidthBudgetBytes / liveJobsOnThatNode` and feeds it to `migrateSetParameters` / the cold chunker. Queue depth is surfaced via the existing `infinibay_migration_phase` metric (a `queued` gauge). This is the single admission point — no path fires migrations directly.

**Reservation lifetime (operability cross-reference).** A held `PlacementReservation` backing a MigrationJob must **not** expire at the fixed 120s TTL while gigabytes stream. The Scheduling subsystem owns the fix; the contract this section requires: when a reservation backs a `MigrationJob`, its `expiresAt` is **driven by the job** (renewed on each progress/heartbeat tick) and released only on terminal phase — or the reservation enters a `migrating` state the reaper ignores while `MigrationJob.phase` is non-terminal. The 120s TTL stays only for the create-crash case.

### 4. Live migration — the QEMU sequence

```
MASTER          SOURCE AGENT (running QEMU)        TARGET AGENT
  │  prechecks (CPU⊇, machine-type, capacity, storage)         │
  │── prepareIncoming(spec, jobId, perVmHmacKey) ─────────────▶│
  │                          QEMU -incoming defer (+disk,net,fw,fenceToken)
  │◀────────────────────────────── {host, port, fenceToken} ───│
  │── set-capabilities/parameters ─▶│ (xbzrle, auto-converge,  │
  │                                 │  postcopy off v1; bw=budget)
  │  [non-shared] drive-mirror ─────▶│ NBD export on target ◀───┤
  │── migrate tcp:host:P (TLS) ─────▶│ RAM precopy starts        │
  │── poll query-migrate ───────────▶│ (dirty-rate, ram.remaining)
  │            ...mirror 'ready' + ram 'active→pre-switchover'   │
  │  PERSIST phase=pivoted (before any block-job-complete) ─────│   ◀── crash-safety boundary
  │── block-job-complete (per disk) ▶│ DiskMirrorState.pivoted=true
  │   migration 'completed' ─────────│ source paused             │
  │────────────────────────────────────────────────────────▶│ cont (target resumes)
  │  TX: flip Machine.nodeId + bump version + phase=completed (I3)
  │── teardown(jobId) ─▶│ stop+reap source QEMU, TAP, disk GC   │
```

#### 4.1 Prechecks (`prechecking`)
- **CPU compat:** with `-cpu host` (the `host` default is in `VMLifecycle.ts:437`; `-cpu` is emitted at `QemuCommandBuilder.ts:151`) the guest sees the **source** flags, so the rule is **`targetNode.cpuFlags ⊇ sourceNode.cpuFlags`** (from `Node.cpuFlags Json`). ADR-1 addresses `-cpu host` fragility.
- **Machine-type identity:** same `-machine` (q35 vs pc) and QEMU major/minor (`QMPClient.getGreeting()`, `:237`).
- **Capacity/maintenance/staleness:** reuse `calculateNodeCapacity` (`VMMigrationService.ts:85-93`).
- **Storage classification:** `sharedStorage` ⇒ skip `drive-mirror` (and the `pivoted` phase); else require it.

#### 4.2 New infinization primitives (G5)

```ts
// QemuCommandBuilder: launch paused, awaiting inbound stream.
setIncoming(uri: string): this {            // 'tcp:0.0.0.0:4444' | 'defer'
  this.args.push('-incoming', assertSafeOptionValue(uri, 'incomingUri')); return this
}
```

`'defer'` is preferred: QEMU starts in `inmigrate`, the listen address is armed later via `migrate-incoming` after disks/NBD are open. Spec is byte-identical to source (§5); **no SPICE ticket reuse** (fresh display ticket — console subsystem).

```ts
// QMPClient: migration verbs (thin wrappers over execute, :248)
migrateSetCapabilities(caps: {capability:string;state:boolean}[]): Promise<void>
migrateSetParameters(p: Partial<{'max-bandwidth':number;'downtime-limit':number;
  'xbzrle-cache-size':number;'cpu-throttle-initial':number}>): Promise<void>
migrate(uri: string, opts?: {blk?:boolean;inc?:boolean}): Promise<void>  // 'tcp:HOST:PORT'
migrateIncoming(uri: string): Promise<void>      // target, for 'defer'
queryMigrate(): Promise<QMPMigrationStatus>
migrateCancel(): Promise<void>                   // 'migrate_cancel'
driveMirror(a:{device:string;target:string;sync:'full'|'top'|'incremental';
  format?:string;mode?:'existing'|'absolute-paths'}): Promise<void>
blockJobComplete(device: string): Promise<void>
queryBlockJobs(): Promise<QMPBlockJob[]>         // per-disk mirror state for reconcile (§7)
```

```ts
interface QMPMigrationStatus {
  status:'none'|'setup'|'active'|'pre-switchover'|'device'|'postcopy-active'|'completed'|'failed'|'cancelled'
  ram?:{transferred:number;remaining:number;total:number;'dirty-pages-rate'?:number;'dirty-sync-count'?:number}
  disk?:{transferred:number;remaining:number;total:number}
  'total-time'?:number;'downtime'?:number;error?:string
}
```

`StateSync.ts:22-40` already maps `inmigrate`/`postmigrate` lifecycle states to DB status — that observer now has a producer.

#### 4.3 Tuning & convergence (`activating`)

```ts
interface LiveTuning {
  maxBandwidthBytes: number      // per-job cap; scheduler may lower it (§3.2 budget split)
  downtimeLimitMs: number        // default 300ms; pause budget at switchover
  xbzrle: boolean                // delta-encode re-dirtied pages (default on)
  autoConverge: boolean          // throttle guest vCPU if dirty-rate outpaces net (default on)
  postcopy: boolean              // v2 only — ADR-2
}
```

Coordinator polls `queryMigrate` every ~500ms → `ram.remaining/total → MigrationJob.progress`. `auto-converge` throttles a busy guest until `ram.remaining` fits the downtime window; QEMU goes `active → pre-switchover`. A **wall-clock budget** (default 10 min) bounds non-convergence ⇒ `migrate_cancel` → `rolled_back` (legal: pre-pivot).

#### 4.4 Non-shared storage: drive-mirror + dirty-bitmap + the pivot boundary

For local qcow2: before RAM precopy, target `prepareIncoming` creates blank destination images + NBD; source issues `driveMirror({sync:'full'})` per disk; mirror copies the base then tracks writes via dirty-bitmap. Wait for each mirror block-job to reach `ready`, then start RAM `migrate`. At `pre-switchover`:

1. **Persist `MigrationJob.phase = pivoted` first** (before any `block-job-complete`). This is the crash-safety boundary.
2. `block-job-complete` each mirror; set `DiskMirrorState.pivoted=true` per disk. This pivots the source's block backend onto the target's NBD/disk — the source's local qcow2 is **no longer authoritative**.
3. Only then `cont` the target, then the I3 switchover TX.

Order: **disks ready ⇒ RAM converged ⇒ persist `pivoted` ⇒ block-job-complete ⇒ cont target.** A reverse pivot risks a write landing only on the source. The persisted `pivoted` flag is what makes post-pivot crash recovery safe (§7) — "who is running" alone cannot distinguish pre- from post-pivot (both sides are paused in that window).

### 5. The launch spec — one source of truth

`prepareIncoming` (target) and cold relaunch need the *exact* QEMU invocation. A serializable `VmLaunchSpec` is derived by the master from `Machine` + `MachineConfiguration` and shipped in the RPC; the agent reconstructs an identical `QemuCommandBuilder`. This removes source/target argv drift (differing `-machine`/device models ⇒ target aborts the incoming stream). The spec carries the **per-VM HMAC key** (`HMAC(master, vmId)`, §1) so the migrated guest's host→guest commands verify on the target — **never** the master secret. Cold and live share the spec.

### 6. Failure modes & recovery

| Phase | Failure | Recovery |
|------|---------|----------|
| prechecking | CPU/machine-type/capacity mismatch | `failed`; zero side effects |
| preparing | target `prepareIncoming` fails / port unreachable | `failed`; **MigrationJob-aware reconcile** on target tears down the incoming QEMU (§7), not the node reaper |
| copying (cold) | stream abort / checksum mismatch | `rolled_back`; delete partial target disk; source intact (I2) |
| copying/activating (live, **pre-pivot**) | mirror/precopy stalls past budget | `migrate_cancel` on source (still running) → `rolled_back`; target QEMU killed + disks GC'd |
| **pivoted** (post-`block-job-complete`) | master/agent crash before `cont(target)` | **Finish-forward only.** Reconcile reads `phase=pivoted` + per-disk `queryBlockJobs` on both agents; `cont` target, kill source. **Never re-cont source** (its backend is pivoted) |
| switching | `cont` on target fails (still pre-pivot, shared-storage) | re-`cont` source, cancel target, `rolled_back`. Never leave both paused |
| switching | master crash between `cont(target)` and TX commit | target QEMU `running` for a VM whose `nodeId` still = source ⇒ promote target (flip nodeId+version, kill source) |
| teardown | source teardown fails after success | job `completed`; orphan source QEMU reaped by source node reaper; alarm |

Universal: **pre-pivot, target failure never harms the source. Post-pivot, source is no longer authoritative and the only safe direction is forward.**

### 7. Idempotency, fencing & crash recovery

- Every agent verb is keyed by `jobId` and idempotent: re-sent `prepareIncoming` returns the existing endpoint; `importDisk` resumes from `bytesDone`; `migrate` no-ops if already `active`.
- **Fence token (I4):** `Machine.migrationJobId` set when a job leaves `queued`, cleared on terminal. Agents refuse any verb whose `jobId ≠` current `migrationJobId`.

- **MigrationJob-aware reconciliation (fixes the mid-migration leak).** The G0 node-scoped reaper alone cannot see an in-flight VM: during `prepareIncoming` the target launches a paused QEMU for a machine whose `Machine.nodeId` is still the **source** (I3 flip happens only at switchover), so the target's `findRunningVMs(targetNodeId)`/`attachToRunningVMs(targetNodeId)` miss it and its reaper treats it as foreign. Therefore each agent's reconcile, on boot/attach, additionally enumerates VMs where **it is the `targetNodeId` or `sourceNodeId` of a non-terminal `MigrationJob`** (master ships this set in the attach handshake) and reconciles incoming/outgoing QEMU against that job's `phase` + fence token:
  - **Target, job not yet `pivoted` (or shared-storage, not yet `switching`):** the incoming/paused QEMU is **unconfirmed**. Tear it down (kill QEMU, drop NBD export, free port+dest disk) and signal the master, which re-drives from a clean `preparing` (or fails the job). Prevents the un-reapable, port-pinning leak.
  - **Target, job `pivoted` or beyond:** the incoming QEMU is **authoritative-elect** — do **not** kill it; finish-forward (`cont` if paused at `inmigrate`/`pre-switchover`, then await/complete the I3 TX).
  - **Source:** if job terminal `completed`, reap the source QEMU (post-switch GC). If non-terminal and **pre-pivot**, keep source running (rollback target). If **post-pivot**, source is non-authoritative ⇒ kill it after the target is confirmed running.
- **Pivot-keyed decision (fixes the post-pivot rollback hazard).** Reconcile keys finish-forward vs rollback on the persisted `MigrationJob.phase`/`DiskMirrorState.pivoted`, **not** on `getStatus` alone. Rule: rollback-to-source is permitted **only strictly before any `block-job-complete`** (`phase < pivoted`); at/after `pivoted` the only resolution is finish-forward. The reconciler verifies per-disk mirror state via `queryBlockJobs` on **both** agents before choosing, so a partially-pivoted multi-disk VM is never half-rolled-back.
- **Heartbeat ↔ migration coordination (fixes the drift-correction race).** Heartbeat is **agent-push lease-renewal** (resolved in favour of Observability-ops §1/ADR-2; the fencing proof needs agent self-fence on failed renewal — `AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD`, plus a softdog watchdog). Cross-reference: **Control-Plane §7/ADR-CP4 must be rewritten from master-pull to agent-push.** Each heartbeat's `nodeId`/`vms[]` is bound to the mTLS cert identity. The master's drift-corrector **excludes any machine with non-null `Machine.migrationJobId`** from status reconciliation: while a migration owns the VM, the coordinator is the **sole writer** of `Machine.status`/`nodeId`. The source agent still reports the in-flight VM in `vms[]`, but the master must not let that observed `paused`/`running` overwrite the coordinator's `activating`/`pivoted` bookkeeping (which would corrupt I3 ordering). Heartbeat ingest still updates node liveness/metrics for fenced machines — just not their `status`.
- **Startup reconciliation** (master + each agent): for each non-terminal `MigrationJob`, re-derive ground truth from `getStatus`/`queryMigrate`/`queryBlockJobs` on both agents and resolve per the table + pivot rule above. The DB row (`phase`, `pivoted`, `migrationJobId`, `version`) + `/proc` truth on two nodes is sufficient — no distributed locks.
- Source-disk GC (cold-copy) is deferred to a post-switch reaper that runs only after confirmed target `getStatus=running` (closes I2 across coordinator restart).

### 8. ADRs

**ADR-1 — Baseline CPU model vs `-cpu host`.** *Decision:* keep `-cpu host` default; allow a per-cluster **baseline CPU model** (`Westmere`/`x86-64-v2`) when a VM is flagged migratable. *Rationale:* `-cpu host` exposes source flags; a guest using AVX-512 absent on the target faults mid-flight. A baseline model masks host-specific flags so any node is a valid target. *Rejected:* identical-CPU fleet (too rigid); live flag-narrowing (guest already booted wide). *Consequences:* small perf loss; precheck becomes trivial `targetNode.cpuFlags ⊇ baseline`.

**ADR-2 — No postcopy in v1.** *Decision:* precopy + `auto-converge` + `xbzrle`; gate `postcopy-ram` behind v2. *Rationale:* postcopy makes the target authoritative with pages still on source — a blip kills the guest on both sides; precopy always permits clean `migrate_cancel` rollback (pre-pivot). *Consequences:* extreme-dirty-rate VMs fall back to `rolled_back`/cold-migrate. Acceptable for VDI.

**ADR-3 — Target-pull streaming for cold-copy.** *Decision:* target pulls, checksum-gated, no source delete pre-confirmation. *Rationale:* backpressure, resumable `bytesDone`. *Rejected:* source-push (no backpressure, needs target listener); shared scratch (defeats the point). *Consequences:* source `exportDisk` must produce a stable checksummed handle for a stopped VM (trivial — disk quiescent).

**ADR-4 — Peer disk channel: master-proxied by default, direct-TLS opt-in.** *Decision:* v1 proxies all cross-node disk/NBD bytes **through the master** over existing master↔agent mTLS; large fleets may opt into **direct mutual-TLS** peer streams (dual-EKU node certs + cert-pinning + job-scoped `peerToken` bound to `MigrationJob.id`, NBD inside the TLS tunnel on the overlay plane). *Rationale:* the default needs **no PKI change** (node certs stay `clientAuth`-only) and inherits confidentiality + peer auth from management mTLS; raw NBD/cleartext on the LAN is never an option. *Rejected:* unauthenticated direct NBD (tenant disk exfiltration / injection during `importDisk`); relying on SHA-256 for channel security (it is integrity-only). *Consequences:* default pays a double LAN hop through the master NIC, bounded by the §3.2 bandwidth budget; opt-in (b) requires the Onboarding PKI to add `serverAuth` to node certs.

**ADR-5 — Master-side migration scheduler with hard concurrency caps.** *Decision:* all migrations are admitted by a single master scheduler enforcing per-source/per-target/cluster-wide limits + per-node aggregate bandwidth budget. *Rationale:* drains/evacuations otherwise fire ~50 concurrent jobs, saturating NICs/disks and throttling many guests via N simultaneous auto-converge. *Rejected:* per-job `maxBandwidthBytes` alone (does not bound the aggregate); unbounded fan-out. *Consequences:* drains enqueue (largest-first) and wait for slots; queue depth surfaced via `infinibay_migration_phase`.

### 9. Dependencies (designed elsewhere)
- **Node Agent RPC:** `prepareIncoming`(now carrying `perVmHmacKey`), `startLiveMigration`, `exportDisk`/`importDisk`, `getStatus`, `teardown`, `queryBlockJobs`, mTLS transport, and the **peer data channel** (ADR-4 mechanics + any firewall opening).
- **NodeDispatcher:** `machineId → agent` resolution; the non-terminal-MigrationJob set shipped in the attach handshake.
- **G0 node-scoped reaper:** never cross-kills; **extended to be MigrationJob-aware** (§7) so in-flight QEMU is owned by the job.
- **Heartbeat/liveness (Observability-ops; Control-Plane to be aligned):** agent-push lease renewal + self-fence; cert-bound `vms[]`; drift-corrector skips fenced machines.
- **Scheduling:** reservation lifetime tied to MigrationJob (§3.2); DRS/evacuation enqueues into the scheduler.
- **Security-RBAC / Deployment-Installer:** per-VM HMAC key derivation + JIT delivery; master secret never on nodes.
- **Console/display:** post-switch `graphicHost` + fresh SPICE ticket.

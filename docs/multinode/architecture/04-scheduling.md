## VM Scheduling & Placement

The current `NodePlacementService` (`repos/backend/app/services/node/NodePlacementService.ts:28-76`) is a single-pass best-fit heuristic: it loads every node + its machines, computes capacity, filters `fits`, then sorts **local-first** (`:69`) and worst-fit (most-free-cores). This is fine for one box and structurally wrong for a cluster: (a) no atomic reservation — two concurrent creates read identical capacity and double-book a node; (b) a hard local preference that defeats spreading once N>1; (c) no overcommit, no disk accounting (`NodeCapacity.ts:49` hardcodes `availableDiskGB: null`); (d) no GPU/CPU-feature/label constraints; (e) staleness from `updatedAt` not `lastHeartbeat`. This section replaces the heuristic with a constraint-based scheduler while keeping the same entry point and signature so callers (`CreateMachineServiceV2.ts:95`, `machineLifecycleService.ts:95`) change minimally.

### Capacity accounting

Capacity is **allocatable**, not raw. Reserved is the sum over machines that count against a node — anything not in a terminal/off-without-claim state. We extend `NodeCapacity` to model overcommit and disk, and to derive health from heartbeat (plan G3):

```ts
export interface OvercommitRatios { cpu: number; ram: number; disk: number } // e.g. {cpu:4, ram:1, disk:1.2}
export interface SystemReserve   { cpuCores: number; ramGB: number; diskGB: number } // host/hypervisor headroom

export interface NodeCapacityV2 {
  reserved:        NodeResourceTotals     // Σ running+claimed VM specs on this nodeId
  allocatable:     NodeResourceTotals     // total*overcommit - systemReserve
  available:       NodeResourceTotals     // allocatable - reserved   (may go negative -> unschedulable)
  pressure:        { cpu: number; ram: number; disk: number } // reserved/allocatable in [0,1+]
  health:          'online' | 'stale' | 'offline'  // == nodeHealth(node); see Observability §1 (owner)
  schedulable:     boolean                          // nodeHealth==='online' && !maintenanceMode
}
```

`allocatable.cpuCores = floor(node.cores * ratios.cpu) - systemReserve.cpuCores`. RAM is **not** overcommitted by default (`ratios.ram = 1`) because ballooning/OOM on a VDI host kills live desktops; CPU overcommits because desktops are bursty and mostly idle. Ratios live in `Node.labels` (per-node) falling back to a cluster default, so a GPU/compute node can opt out. Disk reserved counts thin-provisioned `diskSizeGB` × `ratios.disk`; for golden-image linked clones the *backing* file is shared, so only the per-VM overlay delta is charged (see below).

`reserved` is recomputed from rows scoped to the node — and critically must include **active placement reservations** (next section), not just committed `Machine` rows, or the race reopens.

**Single owner of node health (resolves the four-way respec).** `nodeHealth()` / `NODE_STALE_AFTER_MS` (`NodeCapacity.ts:1`) and the three-valued `'online'|'stale'|'offline'` return are **owned by Observability §1**, which holds the concrete implementation; Control-Plane §7, Data-Model "Desired vs observed", and this section all *consume* it and must not redefine staleness. The semantic question that previously differed between owners is resolved here once: a node in `status='approved'` (paired but **pre-first-heartbeat**) is **not schedulable** — `nodeHealth` returns `'stale'` until the first lease renewal lands, because admitting work to a node we have never heard execute risks scheduling onto a host that cannot actually run QEMU. `schedulable` is therefore exactly `nodeHealth(node)==='online' && !maintenanceMode` (online already implies a fresh heartbeat *and* an approved status), collapsing the prior boolean-vs-enum and approved-vs-online disagreements into one predicate over one source of truth.

> Liveness note: `nodeHealth`'s `'stale'/'offline'` transitions are driven by the **agent-push lease-renewal heartbeat** (Observability §1 / ADR-2), *not* master-pull. The scheduler treats a node whose lease has lapsed past `NODE_STALE_AFTER_MS` as unschedulable and excludes it; the agent self-fences its own VMs before the master declares it dead (`AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD`), so the scheduler never re-places a VM onto a surviving host while the partitioned source is still writing shared storage. The heartbeat *direction and fencing inequality are owned by Observability §1*; this section only consumes the resulting health.

### Placement request / response

```ts
export interface PlacementRequest {
  vmId?: string                 // present on migration/rebalance, absent on create
  cpuCores: number; ramGB: number; diskSizeGB: number
  requiredFlags?: string[]      // CPU features the guest needs (matched vs Node.cpuFlags)
  machineType?: string          // q35 / pc-i440fx — must match for future live-migrate
  gpu?: { vendor: string; required: boolean }     // passthrough class request -> node label match
  requiredLabels?: Record<string,string>          // hard: {"zone":"rack-a"}
  affinity?:    { poolId?: string; antiAffinityScope?: 'pool'|'none' }
  locality?:    { goldenImageId?: string; sourceNodeId?: string } // soft hints
  policy:       'spread' | 'binpack'
}
export interface PlacementResult {
  nodeId: string
  reservationId: string         // MUST be committed or released by the caller
  score: number
  reasons: string[]             // audit: why this node, why others were filtered
}
```

### Two-stage pipeline: hard filter → soft score

```
candidates = nodes.filter(HARD).map(SOFT-score).sort(desc).head
HARD (predicate, any false => excluded, reason recorded):
  schedulable           nodeHealth==='online' && !maintenanceMode   (Observability §1 owns nodeHealth)
  fitsCpu/Ram/Disk      available.* - request.* >= 0   (post-reservation)
  cpuFeature            requiredFlags ⊆ Node.cpuFlags        (Json, already exists)
  gpu                   !gpu.required || node.labels.gpu===vendor && a free vfio device exists
  labels               requiredLabels ⊆ Node.labels
  antiAffinity          pool scope: node hosts 0 VMs of this poolId (hard for HA pools)
SOFT (weighted sum, higher=better):
  capacityFit           binpack: prefer high pressure (pack);  spread: prefer low pressure
  localityGolden        +W if Node already has goldenImageId base disk (no cross-node copy)
  localitySource        +W if node==sourceNodeId (migration: no-op move) — but DRS sets -∞
  balanceJitter         small random tiebreak to avoid thundering-herd on equal nodes
```

The hard local preference at `NodePlacementService.ts:69` is **deleted**; "local" becomes one soft signal (`localityGolden`/`localitySource`) only. Default `policy` is `spread` for interactive desktops (blast-radius), `binpack` is selectable per pool/department to consolidate for power-down.

### Atomic reservation — the race

Today `chooseNodeForMachine` and `machine.create` run in the same `$transaction` (`machineLifecycleService.ts:95`, `CreateMachineServiceV2.ts:74-130`), but the capacity read at `:29` takes **no lock**, and Postgres default Read-Committed lets two concurrent creates both observe a node as free and both insert — silent overcommit. We make reservation atomic with a row lock + a short-lived `PlacementReservation` table that capacity accounting reads:

```prisma
model PlacementReservation {
  id          String   @id @default(uuid())
  nodeId      String
  cpuCores    Int
  ramGB       Int
  diskGB      Int
  vmId        String?                 // set once the Machine row exists
  state       String   @default("held")  // held | committed | migrating | released | expired
  migrationJobId String?              // set when this reservation backs a MigrationJob
  expiresAt   DateTime                 // TTL — reaped only in state='held' (create-crash case)
  createdAt   DateTime @default(now())
  @@index([nodeId, state])
  @@index([migrationJobId])
}
```

```ts
async place(req: PlacementRequest, tx: Prisma.TransactionClient): Promise<PlacementResult> {
  const candidates = await this.hardFilter(req, tx)        // unlocked read, cheap prune
  for (const c of this.scoreSort(candidates, req)) {
    // serialize per-node: lock the Node row so concurrent placers queue here
    await tx.$executeRaw`SELECT id FROM "Node" WHERE id=${c.nodeId} FOR UPDATE`
    const cap = await this.capacityFromCounter(c.nodeId, tx)  // reads denormalized counter, O(1)
    if (cap.available.cpuCores >= req.cpuCores && cap.available.ramGB >= req.ramGB
        && cap.available.diskGB >= req.diskSizeGB) {
      const r = await tx.placementReservation.create({ data: { nodeId:c.nodeId, /*...*/ state:'held',
        expiresAt: new Date(Date.now()+120_000) } })
      await this.bumpReserved(c.nodeId, +req, tx)          // counter += this reservation, same tx
      return { nodeId:c.nodeId, reservationId:r.id, score:c.score, reasons:c.reasons }
    } // else: someone took it under the lock — fall through to next candidate
  }
  throw new NoCapacityError(req, /* per-node reasons */)
}
```

`FOR UPDATE` on the `Node` row is the serialization point: the second placer blocks until the first commits its reservation, then re-reads capacity *including* that held reservation and correctly skips the now-full node. `commitReservation(reservationId, vmId)` flips state to `committed` and is called in the **same** transaction that inserts the `Machine`; an aborted create rolls back the held row automatically, and a crashed process leaks at most one row until the TTL reaper (`state='held' && expiresAt < now()`) sweeps it. This is a pessimistic per-node lock, not a global one — placements onto different nodes proceed in parallel.

**Denormalized reserved counter (resolves O(placements × VMs_per_node)).** The locked critical section must read **one row**, not re-aggregate. Each `Node` carries a 1:1 `NodeReserved { nodeId, cpuCores, ramGB, diskGB }` counter (or three columns on `Node`) that is the running sum of *committed Machines + held/migrating reservations*. It is mutated transactionally inside the same lock window on every reservation commit/release, `Machine` create/delete, and migration completion (`bumpReserved`). `capacityFromCounter` then reads the single counter row already pinned by `FOR UPDATE`, so lock-hold time is O(1) regardless of the node's ~50 existing Machines. The counter is reconcilable: a periodic job (and the node-scoped reconcile, plan G0) re-derives the true sum from rows and corrects drift, so the denormalized value is an optimization, never the source of truth for correctness audits.

### Batch placement for pool refill

Pool refill of hundreds of desktops should not fire N independent locked `place()` calls that all queue on the same hot writer. `placeBatch(reqs[])` computes a **spread plan for the whole batch in one pass**: it snapshots all candidate counters, applies anti-affinity (`at most one new pool VM per node per round`) and the soft score, decrements an in-memory working copy of each node's reserved as it assigns, and only then takes the per-node `FOR UPDATE` locks **once per touched node** to materialize all reservations for that node together. This turns a refill from `O(batch)` lock acquisitions into `O(distinct target nodes)` and removes the per-placement re-aggregation entirely. Single creates keep the simple `place()` path.

> **ADR-S1 — Reservation table + `SELECT … FOR UPDATE` over advisory locks or serializable retry.**
> *Decision:* per-node row lock guarding a reservation table that a denormalized per-node counter folds into capacity reads.
> *Rationale:* keeps the existing single-transaction create path (`CreateMachineServiceV2.ts:74`) intact; capacity is always derivable from DB state (committed + held + migrating), so the coordinator and the node agent's reconcile agree; reservations give us a natural audit + TTL self-heal; the counter keeps the locked window O(1).
> *Alternatives rejected:* (a) `pg_advisory_xact_lock(hash(nodeId))` — works but invisible to other readers and to ops tooling; (b) `SERIALIZABLE` + retry — global abort storms under create bursts, and we'd still need a reservation concept for multi-step (GPU claim, disk copy) placements; (c) optimistic `Machine.version` CAS — doesn't compose across the agent RPC where the VM row may not exist yet.
> *Consequences:* one extra table + a 1:1 counter + a reaper job; the counter must be maintained transactionally and reconciled; lock is held for the (sub-millisecond) counter-read window only.

### Reservation lifetime is bound to the operation, not a fixed TTL

The 120s TTL exists **only** to free a reservation whose creating process crashed before `commitReservation` — the create-crash case. It must **not** govern a reservation that backs a multi-step migration: cold-copy streams gigabytes of overlay and live precopy has a ~10-min wall-clock budget, both routinely exceeding 120s, so a fixed TTL would let the reaper free the target's reservation mid-migration and a concurrent create would double-book the destination into overcommit. Fix:

- When a reservation is created to back a `MigrationJob`, it is created in (or transitioned to) **`state='migrating'`** with `migrationJobId` set. The TTL reaper sweeps **only `state='held'`** rows; `migrating` rows are invisible to it while `MigrationJob.phase` is non-terminal.
- `expiresAt` for a `migrating` reservation is treated as a **watchdog renewed on each migration progress tick** (the same tick that advances `MigrationJob.progress`); if the job stops ticking for `> 2× tick interval` the reservation is reclaimable, covering a wedged migration without freeing a healthy long-running one.
- The reservation is released (or committed to the new node) **only on a terminal phase** (`completed` → commit on target, rebump source/target counters; `failed`/`rolled_back` → release on target, VM stays on source). This makes the drain plan genuinely capacity-consistent for the multi-step case it was designed for.

### Where it plugs into CreateMachineServiceV2

`CreateMachineServiceV2.ts:95` changes from `chooseNodeForMachine({cpu,ram,disk})` to building a full `PlacementRequest` from the template/custom specs already computed at `:42-68`, the GPU request from `input.pciBus` (`:114`), and pool/golden-image context. The returned `reservationId` is committed alongside `tx.machine.create` (`:101`). The **GPU passthrough preflight** (`verifyGpuPassthrough`, `CreateMachineServiceV2.ts:202-258`) currently inspects local `/sys` — in multi-node it must run on the *chosen* node via the **NodeDispatcher** (see *Node Agent / RPC* subsystem): scheduling only guarantees the node is *labeled* GPU-capable and a vfio device is *accounted* free; the agent's `preflightGpu(pciClass)` confirms the physical bind before the reservation commits, else the scheduler re-places excluding that node.

```
createMachine ──▶ build PlacementRequest ──▶ scheduler.place() ─┬─ NoCapacity ▶ UserInputError(no host fits)
                                                                └─ {nodeId, reservationId}
                              ▼ (same tx)
   agent.preflightGpu(nodeId) ──fail──▶ exclude node, retry place (≤K)
                              ▼ ok
   tx.machine.create({ nodeId, ... }) + commitReservation(reservationId, machine.id)  ──commit──▶ dispatch createVM to agent
```

> Per-VM secret provisioning at create/migrate time is **owned by Security-RBAC §1/§4 + Deployment-Installer §8**: the master derives `HMAC(INFINISERVICE_HMAC_MASTER_SECRET, vmId)` and ships **only that per-VM key** over the authenticated mTLS RPC to the node currently hosting the VM (and to the destination node JIT at migration). `INFINISERVICE_HMAC_MASTER_SECRET` **never lands on a compute node**, so a compromised node forges host→guest commands for its own VMs only. The scheduler's contribution is merely supplying the `targetNodeId` to that JIT push at place/migrate time; it stores no secrets.

### Pool desktops & golden-image scheduling

Non-persistent pools (`Pool`, `type='non-persistent'`, `NonPersistentResetService`) schedule each desktop as an independent `PlacementRequest` with `affinity.antiAffinityScope='pool'` so a single node failure can't take an entire pool offline — the hard anti-affinity admits at most one new pool VM per node per placement round, soft-degrading to spread when the pool is larger than the node count. `locality.goldenImageId` is a strong soft signal: linked clones (`useLinkedClone`, `CreateMachineServiceV2.ts:343`) boot from `goldenImage.baseDiskPath`, which is **node-local**, so co-locating with a node that already holds the base disk avoids a cross-node base-image copy; if no node has it, the scheduler picks by score and the *image-distribution* concern (pre-seeding the base qcow2) is delegated to the storage subsystem. Disk accounting charges pool clones only their overlay delta, so a node can pack far more non-persistent desktops than its raw disk would suggest. Pool refill (the background job that maintains `sizeMin`) calls `placeBatch()` (above) per refill round, so anti-affinity and capacity are re-evaluated continuously, not just at pool creation, without serializing on a single node lock.

### Rebalancing / DRS-style evacuation — with a migration scheduler

`setNodeMaintenanceMode(nodeId, true)` triggers a **drain plan**: enumerate the node's `Machine` rows, and for each, run `place()` with `vmId` set, `locality.sourceNodeId=nodeId`, and that source node forced out of the candidate set. The scheduler emits an ordered evacuation plan (largest-VM-first to reduce fragmentation); each planned move pre-allocates a `migrating`-state reservation on its target (lifetime bound to its `MigrationJob`, per above) so the plan is capacity-consistent before any migration starts. If any VM has no feasible target, the drain reports `partial` and surfaces the offending VMs rather than half-evacuating.

Crucially, the plan is **not fired all at once**. A node-death evacuation or maintenance drain of ~50 VMs that simultaneously cold-copies every overlay or runs N auto-converge live migrations saturates source/target NICs and disks and throttles many guests' vCPUs at once — `LiveTuning.maxBandwidthBytes` is per-migration and cannot bound aggregate load. We interpose a **master-side `MigrationScheduler`** that owns admission of `MigrationJob`s:

```ts
export interface MigrationLimits {
  maxPerSourceNode: number      // e.g. 2  — concurrent jobs leaving one node
  maxPerTargetNode: number      // e.g. 2  — concurrent jobs landing on one node
  maxClusterWide:   number      // e.g. 8  — total in-flight across the fleet
  nodeBandwidthBudgetBytes: number // per-node aggregate ceiling, split across that node's in-flight jobs
}

// admission: a queued MigrationJob (phase='queued') becomes 'preparing' only when
//   inflight(source) < maxPerSourceNode && inflight(target) < maxPerTargetNode
//   && inflightCluster < maxClusterWide
// on admit, each job's effective LiveTuning.maxBandwidthBytes =
//   floor(nodeBandwidthBudgetBytes / inflight_on_that_node)   // re-divided as jobs enter/leave
```

Drain/evacuation **enqueues** jobs (largest-first ordering preserved) at `MigrationJob.phase='queued'` (the model already has `queued`, `02-implementation-plan.md:101`); the scheduler admits against the three concurrency caps and divides each node's bandwidth budget across its currently in-flight jobs, re-balancing the per-job `maxBandwidthBytes` as jobs complete. Queue depth (count of `phase='queued'`) is surfaced via the existing `infinibay_migration_phase` metric so operators see a drain backing up rather than a NIC melting. The migration *execution* (QMP `migrate`, `query-migrate` polling, `VMStorageMigrationAdapter` copy-vs-shared) remains **owned by the Migration / Storage subsystems**; the scheduler owns only *which* jobs run *when* and at *what bandwidth*.

```
            ┌──────── node states (scheduler view) ────────┐
 pending ─▶ approved ─▶ online ⇄ stale ─▶ offline
            (not        │  ▲                 │
          schedulable)  │  └── lease renew ──┘
            maintenance ◀─┘
              (drain: source for evacuation, sink for none)
```

Steady-state DRS (continuous rebalancing on imbalance) is explicitly **out of v1**: it requires real utilization telemetry (heartbeat CPU/RAM, not just reserved sums) and a migration-cost model, and live-migration must land first. v1 rebalancing is *event-driven only* (maintenance drain, manual `migrateMachineToNode`) and always flows through the `MigrationScheduler`'s caps.

### Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| Two creates race one node | `FOR UPDATE` serializes; 2nd re-reads counter incl. held reservation | 2nd skips to next candidate or `NoCapacity` |
| Create crashes after reserve, before commit | `state='held' && expiresAt < now()` | TTL reaper releases the held row + decrements counter |
| Migration outlives 120s TTL | reservation is `state='migrating'` | reaper ignores it; released only on terminal `MigrationJob.phase` |
| Node goes stale mid-placement | `nodeHealth` (Observability §1) lease lapse | filtered out of candidates; in-flight `held` reservation expires |
| GPU labeled free but physically bound | agent `preflightGpu` fails | exclude node, re-place (≤K retries) |
| Drain saturates NIC/disk | `MigrationScheduler` caps + per-node bandwidth budget | jobs queue at `phase='queued'`; depth visible via `infinibay_migration_phase` |
| All nodes full | empty candidate set | `NoCapacityError` with per-node `reasons` → UI surfaces pressure |
| Reserved counter drift vs real `/proc` | node-scoped reconcile (plan G0) + periodic re-aggregate | agent reports truth; coordinator corrects `Machine`/reservation rows + rebuilds counter |

> **ADR-S2 — Reserved (sum-of-specs) admission, not live-utilization admission.** *Decision:* schedule on declared `cpuCores/ramGB/diskSizeGB`, overcommit via ratios, treat live heartbeat metrics as advisory only. *Rationale:* deterministic, race-safe, and computable inside the create transaction without trusting node telemetry that lags by up to `NODE_STALE_AFTER_MS` (`NodeCapacity.ts:1`). *Alternatives rejected:* utilization-based bin-packing (needs trusted real-time metrics + admission hysteresis — defer to DRS phase). *Consequences:* a node can be "full" on reservation while idle on real CPU; overcommit ratios are the tuning knob, and binpack policy plus future DRS reclaim the slack.

> **ADR-S3 — Migration admission is centralized and capped, not per-job.** *Decision:* all `MigrationJob`s pass through a master-side `MigrationScheduler` enforcing per-source / per-target / cluster-wide concurrency caps and a per-node aggregate bandwidth budget that subdivides `LiveTuning.maxBandwidthBytes` across in-flight jobs. *Rationale:* a single drain/evacuation of ~50 VMs otherwise saturates NICs/disks and auto-converge throttles many guests at once; per-migration limits cannot bound aggregate load. *Alternatives rejected:* (a) rely on `maxBandwidthBytes` alone — per-job only, no aggregate ceiling; (b) unbounded parallel evacuation — collapses source/target I/O; (c) fixed serial (one-at-a-time) — needlessly slow when source and target have headroom. *Consequences:* drains complete more slowly but predictably; a queue exists (depth on `infinibay_migration_phase`); the scheduler must re-divide bandwidth as jobs enter/leave.

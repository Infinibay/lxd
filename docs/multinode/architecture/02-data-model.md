## Data Model, Consistency & Command Pipeline

This subsystem owns the persistence layer of the cluster: the single source of truth, how **desired vs. observed** state are represented durably, how the master safely commands stateless agents through one transactional outbox, and the migration/backfill path from today's single-node installs. It depends on the **Node Agent + RPC** subsystem (transport, mTLS, method contracts), the **Onboarding** subsystem (pairing semantics for `Node.status` / underlay IP), and the **Observability/Ops** subsystem (which owns `nodeHealth`, the heartbeat/lease loop, and the fencing decision). It defines the *schema and write rules* those subsystems share; it does not design the transport or the fencing timing.

> **Single-owner pointers (coherence fixes).** `nodeHealth` / `NODE_STALE_AFTER_MS` and the `schedulable` predicate are owned by **Observability §1** (concrete code lives there); this section only *consumes* them and contributes the columns they read (`Node.lastHeartbeat`, `Node.status`, `Node.epoch`). The heartbeat **direction is agent-push lease-renewal** (Observability §1 / ADR-2) — Control-Plane §7/ADR-CP4's "master-pull" wording is superseded and must be rewritten to match, because the no-double-run proof depends on the *agent* self-fencing when it cannot renew. The `NodeCommand` model in Control-Plane §4 is **deleted**; `CommandOutbox` below is the sole master→agent channel.

### ADR-1 — One Postgres on the master; compute nodes are stateless

**Decision.** Keep exactly one Postgres, on the master, as the cluster's sole authoritative store. Compute nodes persist nothing durable; their "state" is `/proc` + local sockets, reconciled against the DB and scoped to their own `nodeId`.

**Rationale.** The codebase already centralizes truth in Postgres and treats infinization's `PrismaAdapter` as a host-agnostic reader (`findRunningVMs` at `PrismaAdapter.ts:438`, optimistic-lock `transitionVMStatus` at `:699`). Distributing the DB would force multi-master reconciliation and directly worsen the G0 cross-kill bug. A single writer gives serializable transactions, one optimistic-lock domain (`Machine.version`, `schema.prisma:245`), and trivially correct `seq` ordering.

**Alternatives rejected.** (a) Postgres-per-node + logical replication — multi-master write conflicts, no clean placement authority. (b) Backend-process-per-node sharing one DB — multiplies the reaper/auth surface (plan §1.3).

**Consequences & the critical safety boundary.** The master is a control-plane SPOF until Phase 5 (streaming replica + multi-coordinator quorum). **Therefore guest liveness MUST be decoupled from control-plane reachability** (see ADR-5): a master restart, leader-election gap, LB blip, or a Postgres pause longer than the lease TTL must **never** translate into a fleet-wide VM kill. The control plane losing the DB is a *management* outage, not a *data* outage. Concretely, bare lease-renewal failure is **not** sufficient grounds to SIGKILL guests; that decision is re-specified in ADR-5 and the fencing mechanics are owned by Observability §3.

### ADR-5 — Self-fence only on positive loss-of-resource, never on bare control-plane unreachability

**Decision.** An agent self-fences (SIGKILLs its local QEMU) **only** when it can *positively confirm* it has lost a contested resource, gated by storage tier:

- **Tier-S (shared/clustered storage)** VMs: fence when the agent observes its **storage lock revoked** (e.g. SCSI PR / image lock lost) **or** learns its `Node.epoch` was **superseded** by a newer lease grant (delivered out-of-band by a peer/quorum, see Observability §3). Either event proves another writer may now own the image → fencing prevents a double-write.
- **Tier-L (local-disk only)** VMs: **never auto-fenced on lease loss.** A local-disk VM cannot be double-run on shared media, so it keeps running through a full control-plane outage. It is fenced only by an explicit, authenticated teardown command once the control plane returns.
- A hardware/softdog watchdog still self-fences a *wedged* (hung, non-renewing-and-non-responsive) agent, independent of master reachability.

**Rationale.** The reviewer-identified blocker: keying SIGKILL to renewal against a single Postgres makes the control plane a single point of *total data loss*. Loss-of-resource fencing inverts that: the trigger is evidence that someone else **already** holds the resource, which is true regardless of whether the master is up. Bare lease timeout is consistent with "master is down" — which by ADR-1 is explicitly survivable.

**Alternatives rejected.** (a) Timeout-only self-fence (`AGENT_SELFFENCE_AT=12s`) keyed to master/DB reachability — rejected: a clean master failover or DB pause >12s kills every desktop simultaneously. (b) Require master HA quorum + clustered Postgres *before* any lease-based fencing — kept as the gate for enabling Tier-S epoch-supersede fencing, but not required for the Tier-L "keep running" path.

**Consequences.** The timing inequality (`AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD`) must be proven to hold *across a master leader failover*, not just a clean single-master run — Observability §3 owns that proof and now carries the storage-tier and epoch-supersede preconditions. Data-model contributes the durable `Node.epoch` and `FenceAction` audit rows below.

### G0 fix at the data layer — node-scoped reads

`findRunningVMs` (`PrismaAdapter.ts:438`) filters `WHERE status='running'` only; `findMachineByInternalName` (`:345`) / `findMachinesByStatuses` (`:482`) ignore node identity. A reaper on node B sees node A's running VMs as local, fails to match a local `/proc` PID, and SIGKILLs — data loss. Fix is additive: thread a **required** `nodeId` filter through every reconciliation read.

```ts
export interface InfinizationOptions { nodeId: string /* …existing… */ }

async findRunningVMs(nodeId: string): Promise<RunningVMRecord[]> {
  return this.prisma.machine.findMany({
    where: { status: 'running', nodeId },          // was: { status: 'running' }
    include: { configuration: { select: RUNNING_VM_CONFIG_SELECT } }
  }); /* …unchanged mapping… */
}
async findMachinesByStatuses(nodeId: string, statuses: string[]) { /* where: { nodeId, status:{in} } */ }
async findMachineByInternalName(nodeId: string, internalName: string) { /* where: { nodeId, internalName } */ }
```

`internalName` is unique only *within* a node post-cluster, so `nodeId` is a correctness fix for name collisions, not just safety. `nodeId` is **required** (a forgotten call site is a compile error), mirroring the fail-closed rule at `:380` (a DB error must not collapse to "not found → kill").

### ADR-CP1 hardening — the master proxy is a node-scoped facade, not a Prisma passthrough (security)

The agent never mutates the DB except through the master's `RpcDatabaseAdapter`, **but the master is the enforcement point, not the agent.** On *every* agent-originated call (proxied DB op and heartbeat), the master derives the caller's `nodeId` from the **verified mTLS client-cert CN** and rejects anything that crosses node boundaries. Agent-supplied `nodeId`/`vmId`/`vms[]` are **untrusted input**; the cert is the only authority.

```ts
// Master side — wraps PrismaAdapter; callerNodeId comes from the TLS session, never the payload.
class NodeScopedDbFacade {
  constructor(private db: PrismaAdapter, private callerNodeId: string /* = cert CN */) {}

  async findMachineByInternalName(name: string) {
    return this.db.findMachineByInternalName(this.callerNodeId, name);     // forced scope
  }
  async updateMachineStatus(machineId: string, status: string, expectVersion: number) {
    const m = await this.db.getMachineNodeId(machineId);
    if (m?.nodeId !== this.callerNodeId) throw new RpcError('NODE_SCOPE_VIOLATION');  // reject cross-node write
    return this.db.transitionVMStatus(machineId, /*…*/ expectVersion);
  }
  // heartbeat ingest: drop any vms[] entry whose Machine.nodeId !== callerNodeId before folding it in.
}
```

This closes the lateral-movement hole: a single compromised agent **cannot** read the fleet's `Machine` table, flip a peer's VM to `off`, or refresh a dead peer's `lastHeartbeat` to block its fencing. Every read is filtered to `callerNodeId`; every write asserts ownership; heartbeat `vms[]` claims for foreign machines are discarded, not folded. (The per-VM HMAC secret distribution model — never ship `INFINISERVICE_HMAC_MASTER_SECRET` to nodes; derive `HMAC(master, vmId)` on the master and push only the per-VM key JIT — is owned by **Deployment-Installer §8 / Security-RBAC**; this section only guarantees the RPC carrying that key is node-scoped as above.)

### Schema evolution

```prisma
model Node {
  // existing: id name currentRaid nextRaid cpuFlags ram cores maintenanceMode createdAt updatedAt disks machines
  role          String    @default("compute")  // "master" | "compute"
  status        String    @default("pending")  // pending|approved|online|offline|rejected|decommissioned
  address       String?                          // LAN-reachable agent host/IP
  agentPort     Int       @default(9443)
  fingerprint   String?   @unique                // SHA-256 of agent client cert (TOFU pin); CN == nodeId
  certPem       String?                          // cert signed by master CA
  joinCodeHash  String?                          // hash of pairing code; never plaintext
  joinNonce     String?
  epoch         Int       @default(0)            // lease generation; bumped in the lease-grant TX (ADR-5/Obs §3)
  lastHeartbeat DateTime?                         // liveness source-of-truth (fixes G3)
  agentVersion  String?
  labels        Json?                             // {"gpu":true,"zone":"rack-a"} for placement
  outbox        CommandOutbox[]
  underlay      NodeUnderlay?
  fences        FenceAction[]
  @@index([status])
  @@index([role, status])
}

model Machine {
  // + version Int @default(1) (exists, :245), nodeId String? (exists, :246)
  desiredState   String   @default("stopped")    // running|stopped — DURABLE power intent (see "Desired vs observed")
  migrationJobId String?                          // non-null ⇒ migration coordinator is SOLE writer of status/nodeId
  // status (:234) stays the OBSERVED power state.
}

/// Per-node overlay endpoint. Populated at onboarding (see Onboarding JoinRequest); single-NIC ⇒ vtepIp = mgmtIp.
model NodeUnderlay {
  nodeId String @id
  vtepIp String                                   // VXLAN VTEP / data-plane IP
  mgmtIp String?
  node   Node   @relation(fields: [nodeId], references: [id], onDelete: Cascade)
}

/// Fence audit — load-bearing for the no-double-run proof (Observability §3/§5 reads this).
model FenceAction {
  id           String   @id @default(uuid())
  nodeId       String
  method       String   // epoch-supersede | storage-lock-revoked | watchdog | manual
  confirmedDown Boolean
  epoch        Int                                 // epoch the fence was issued against
  actor        String                              // coordinator instance / userId
  at           DateTime @default(now())
  node         Node     @relation(fields: [nodeId], references: [id], onDelete: Cascade)
  @@index([nodeId, at])
}

model MigrationJob {
  id           String   @id @default(uuid())
  machineId    String
  sourceNodeId String?
  targetNodeId String
  mode         String   // cold-shared | cold-copy | live
  phase        String   // queued|preparing|copying|activating|completed|failed|rolled_back
  progress     Int      @default(0)
  bytesTotal   BigInt?
  bytesDone    BigInt?
  error        String?
  createdAt    DateTime @default(now())
  updatedAt    DateTime @updatedAt
  @@index([machineId]); @@index([phase, targetNodeId])
}

/// SOLE master→agent transactional OUTBOX. One row = one durable command INSTANCE.
model CommandOutbox {
  id             String   @id @default(uuid())     // IS the idempotency key for repeatable verbs (see below)
  nodeId         String
  machineId      String?                            // null for node-level cmds (cordon, etc.)
  seq            BigInt   @default(autoincrement())  // global monotonic; per-(node,machine) FIFO order
  kind           String   // createVM|start|stop|reboot|delete|attachDisk|prepareIncoming|teardown|...
  payload        Json
  idempotencyKey String   @unique                    // = id for repeatable verbs; = hash(machineId,'create') ONLY for createVM
  expectVersion  Int?                                 // Machine.version snapshot at enqueue (primary stale guard)
  status         String   @default("pending")         // pending|leased|dispatched|acked|failed|dead
  supersededBy   String?                              // set when a node-death / migration invalidates this row
  attempts       Int      @default(0)
  pendingSince   DateTime @default(now())             // bound on time-in-pending (→ dead past limit)
  leaseOwner     String?                              // current leader/pump instance id (failover hand-off)
  leaseExpiry    DateTime?
  lastError      String?
  createdAt      DateTime @default(now())
  dispatchedAt   DateTime?
  ackedAt        DateTime?
  node           Node     @relation(fields: [nodeId], references: [id], onDelete: Cascade)
  @@index([nodeId, status, seq])                      // dispatcher poll; back with a PARTIAL index on status IN ('pending','leased')
  @@index([machineId, seq])
}

/// Append-only audit/event log, distinct from per-VM SystemEvent (:1075). Partition by month; drop old partitions.
model AuditEvent {
  id         String   @id @default(uuid())
  actorType  String   // user|system|agent
  actorId    String?
  nodeId     String?
  machineId  String?
  action     String   // node.approve | machine.create | machine.migrate | command.dispatch | command.ack | command.dead
  outcome    String   // ok|denied|failed
  detail     Json?
  createdAt  DateTime @default(now())
  @@index([nodeId, createdAt]); @@index([machineId, createdAt]); @@index([action, createdAt])
}
```

`CommandOutbox` supersedes legacy `PendingCommand` (`schema.prisma:694`) for the master→node-agent channel (`PendingCommand` stays for its existing host→guest use). **It also supersedes and replaces `NodeCommand` from Control-Plane §4** — that model is deleted; there is exactly one outbox table, one state set, one ordering guarantee.

### ADR-CP3 (restated) — ONE outbox, leader-gated single command pump

**Decision.** The outbox is drained by a **single command pump that runs only on the elected leader coordinator**. `seq` (BigInt `autoincrement`) gives a total order; the pump dispatches each machine's rows in `seq` order, enforcing **per-`machineId` FIFO** against the machine's *current owning node*. The `leaseOwner`/`leaseExpiry` columns exist so that on leader failover the new leader detects in-flight (`leased`/`dispatched`) rows whose lease has expired and re-drives them. This is **not** an N-way `SKIP LOCKED` race.

**Rationale.** Two divergent pipelines (NodeCommand's leader-pump vs. CommandOutbox's `SKIP LOCKED` multi-dispatcher) would ship as two delivery semantics. A single leader pump gives FIFO for free (no per-lease "scan for older un-acked row" predicate) and matches the leader-election the control plane already needs. Multi-dispatcher `SKIP LOCKED` is recorded as a *future scale-out* path; if adopted, the lease predicate MUST explicitly exclude leasing any row whose `machineId` has an older row in `{pending,leased,dispatched}` (un-acked AND un-superseded) — stated, not implied.

**Consequences.** Throughput ceiling is one leader's dispatch loop; adequate at the design's 20-node/1000-VM target since dispatch is an async RPC fan-out, not a serial wait.

#### FIFO must not deadlock recovery — supersession across a node-death boundary

Per-machine FIFO is enforced **only among commands addressed to the machine's current owning node.** When a node is declared dead, or a machine's `nodeId` flips (migration/evacuate), node-change / cancel / teardown commands **preempt** stale rows rather than queueing behind them:

```ts
// On declare-dead(nodeId) OR on a migration nodeId flip for machineId:
await tx.commandOutbox.updateMany({
  where: { machineId, status: { in: ['pending','leased','dispatched'] }, nodeId: oldNodeId },
  data:  { status: 'dead', supersededBy: newCommandId, lastError: 'superseded: node dead / machine moved' }
});
// then enqueue the migrate/teardown row against the NEW (or no) owning node.
```

This breaks the deadlock where a dead node's pending `start` would otherwise block the very `migrate` issued to rescue the machine. Superseded rows are `dead` (audited), never silently dropped.

### Desired vs. observed state, ordering, and ack authority

- **Desired power state is DURABLE**, in `Machine.desiredState` (`running|stopped`), set **transactionally in the same TX that enqueues** the corresponding Start/Stop `CommandOutbox` row — *not* inferred from "the highest unacked outbox row." Once a Start is acked and its row drains, `desiredState='running'` persists.
- **Observed state** = `Machine.status` + `MachineConfiguration.qemuPid/qmpSocketPath/tapDeviceName`, written by the agent's node-scoped reconcile and by heartbeat drift ingest.
- **Drift** = `observed != desired` for a machine with **no in-flight command** (`migrationJobId IS NULL` and no `{pending,leased,dispatched}` row). When infinization's `HealthMonitor.handleCrashedVM` (`infinization HealthMonitor.ts:883`) flips a crashed VM `running→off`, the cross-node reconciler compares against `desiredState='running'` to decide **restart-vs-leave** — a single-VM crash on a *healthy* node now has a durable anchor, independent of the whole-node HA path (Observability §4).
- **Command lifecycle has a SINGLE authority: the dispatcher's `OpResult`.** Only the pump transitions a `CommandOutbox` row to `acked`/`failed`/`dead`. **Heartbeat ingest never transitions command rows.** If a heartbeat observes a command's end-state without an `OpResult`, that is treated as *drift to reconcile*, not as an ack — so a `REJECTED`/failed command can never be masked by an incidentally-correct observation.
- **Ordering**: `seq` is the total order; per-`machineId` FIFO as in ADR-CP3.

`NodeCapacity.nodeHealth` (`NodeCapacity.ts:27`) switches its input from `updatedAt` to `lastHeartbeat` — but the **function is owned by Observability §1** (including the `'approved'`-is-schedulable question and the `online|stale|offline` return granularity); this section only guarantees the columns it reads. The **master-local node** (`role='master'`, `address='127.0.0.1'`) runs infinization in-process and sends **no RPC heartbeat**; without a refresher it would go stale in 15s and `NodePlacementService` would exclude it, breaking single-host installs. Ownership is assigned: the **leader-gated pump loop refreshes the local node's `lastHeartbeat`/`epoch` every interval from its own `/proc` view** (and Observability §1 additionally treats `role='master'` as liveness-exempt as a backstop). This is on the single-host regression checklist.

### Heartbeat ingest — three concerns, three cadences (scale)

Folding `vms[]` for every VM into a multi-row `Machine` UPDATE every 5s is a single-writer hotspot (200 evals/s, ~50-row TX/node/5s, plus a per-beat metrics upsert). Split it:

1. **Liveness** = one write per node per beat: `Node.lastHeartbeat`, `Node.epoch`. 20 writes/5s, trivial. This is the lease renewal.
2. **Live metrics** (cpu/ram/rss) = held **in-memory on the master and scraped by Prometheus directly**; **not** persisted to Postgres. Prometheus is the retention/TSDB layer; the master `/metrics` re-export from DB (Observability §2) is dropped for VM/host gauges. **Observability §1/§2 owns the metrics surface.**
3. **Drift reconciliation** = diff `vms[]` against DB on a **slower cadence**, `UPDATE` only the rows that actually changed, and **skip the common no-drift case** so steady state is read-only. The diff **excludes** any machine with `migrationJobId IS NULL = false` (see next), and excludes foreign machines per the node-scoped facade.

#### Heartbeat drift must not race the migration coordinator

While a migration owns a VM (`Machine.migrationJobId != NULL`, the I4 fence token), the **migration coordinator is the sole writer of `Machine.status`/`nodeId`.** Heartbeat drift correction **skips** these machines entirely — otherwise the source agent still reporting the VM as `running`/`paused` in its node-scoped `vms[]` would revert the coordinator's `activating`/switchover bookkeeping and corrupt the I3 ordering. Heartbeat may still update node liveness/metrics for that node; it just does not touch fenced machines' status.

### Command pipeline — create VM, end-to-end (persistence view)

```
Client ──GraphQL createMachine──▶ Backend coordinator
  │  [TX BEGIN]
  │   1. NodePlacementService picks nodeId (online + capacity + labels)
  │   2. INSERT Machine(status='creating', desiredState='running', nodeId, version=1) + MachineConfiguration
  │   3. INSERT CommandOutbox(nodeId, machineId, kind='createVM',
  │         idempotencyKey = hash(machineId,'create'),  // createVM is once-per-machine ⇒ content key OK
  │         expectVersion=1, status='pending')
  │   4. INSERT AuditEvent(action='machine.create', outcome='ok')
  │  [TX COMMIT]   ← durable desired-state + command, atomic; no lost/dup command across crash
  ▼
Leader command pump (polls @@index[nodeId,status,seq], leader-only, FIFO per machine):
   lease row → RPC to NodeScopedDbFacade-guarded agent → agent dedupes on idempotencyKey
     AND re-checks LOCAL existence (findMachineByInternalName scoped to nodeId + pidfile)
   → agent spawns QEMU, writes qemuPid via node-scoped PrismaAdapter
   → agent OpResult(ACK) → pump UPDATE CommandOutbox status='acked';
     Machine.status='running' via transitionVMStatus(expectVersion) optimistic lock (:699)
```

#### Idempotency-key rule (correctness)

**The dedup key identifies a command INSTANCE, not a `(machine, verb)` intent.** For every **repeatable** verb (start/stop/reboot/attachDisk/delete), `idempotencyKey = CommandOutbox.id` (the per-instance UUID, already `@unique`). A content-derived key (`hash(machineId,'create')`) is reserved **only** for `createVM`, which is genuinely once-per-`machineId`. This kills the silently-dropped-operation bug: `start → stop → start` now produces three distinct keys, so the second `start` is never mistaken for a replay and the VM actually restarts. The agent dedup cache is keyed by command `id` with a **TTL safely shorter than the minimum gap between distinct user intents** (and far shorter than the pending-row bound below).

#### createVM idempotency does not rely on the dedup cache

Because an offline node's pending row can outlive any fixed dedup TTL, the agent makes `createVM` idempotent against **local state** — `findMachineByInternalName` scoped to `nodeId` + pidfile presence — so a re-apply after TTL expiry is a no-op regardless of cache contents, and never spawns a duplicate VM. Independently, a row may sit `pending` for a node only up to a bound (`pendingSince + MAX_PENDING`); past it the pump moves it to `dead` and alerts, so pending-lifetime and dedup-TTL are not unboundedly decoupled.

The transactional outbox makes delivery **effectively-once**: the command cannot exist without the durable state change (no orphan QEMU) nor the state change without the command (no stuck `creating`). At-least-once on the wire + per-instance idempotency ⇒ effectively-once execution.

### Stale-command guard — version bump is primary, agent self-check is backstop

`expectVersion` (the `Machine.version` snapshot at enqueue) is the **primary** staleness guard, but only if a migration's `nodeId` flip **increments `Machine.version`.** Therefore the migration I3 terminal-phase `nodeId` flip **MUST** go through the existing optimistic-lock path (`transitionVMStatus` / version CAS, `PrismaAdapter.ts:699-814`), not a bare `update`, and bump `version` — it is a logical state change. A Start command enqueued against the pre-migration node then fails `expectVersion` at apply time and is rejected as stale. The agent's `Machine.nodeId === self` assertion (routing a mismatched command to `REJECTED`) is the **backstop**, not the primary guard.

### Failure modes & recovery

| Failure | Detection | Recovery |
|---|---|---|
| Leader pump crashes mid-delivery | new leader sees `leased`/`dispatched` past `leaseExpiry` | new leader re-drives the row; agent dedupes on `idempotencyKey` (= command id) |
| Agent applied cmd but OpResult lost | row stuck `dispatched` past lease | re-dispatch; idempotent no-op on agent (local existence check); heartbeat later confirms observed state |
| Node offline | `lastHeartbeat` stale (`NODE_STALE_AFTER_MS`, Observability §1) | `status→offline`; placement excludes; rows hold `pending` until back or `MAX_PENDING`→`dead`; migrate/teardown **supersedes** them |
| **Control-plane / DB outage** | agents cannot renew lease | **guests keep running** (ADR-5): Tier-L never fenced; Tier-S fenced only on epoch-supersede / storage-lock-revoked. No fleet-wide kill. |
| Node declared dead with in-flight cmds | declare-dead TX | pending/inflight rows for that node `→ dead` (`supersededBy`); HA/evacuate path enqueues fresh rows (Observability §4) |
| Poison command | `attempts ≥ N` | `status='dead'`, `AuditEvent(outcome='failed')`, surfaced in UI; never blocks other machines |
| Concurrent edit | `transitionVMStatus` VERSION_CONFLICT (`:748`) | caller retries with fresh version (P2034 retry already at `:805`) |

### Retention & vacuum (scale)

`CommandOutbox` churns 4+ writes per VM op; a pool refill of hundreds of VMs floods it. Define retention: a periodic job **archives/deletes `acked`/`dead` rows past a horizon** (or time-partition and drop old partitions); the dispatcher poll uses a **partial index on `status IN ('pending','leased')`** so it never scans acked history; **autovacuum is tuned aggressively for the outbox** (high dead-tuple churn). `AuditEvent` and metrics (if any persisted) are **partitioned by month**, old partitions dropped on a retention policy.

### Migrations & backfill (single-node → master-local node)

One Prisma migration adds the columns/models above (all nullable or defaulted → no rewrite of existing `Machine` rows). An idempotent data-backfill runs once on master upgrade:

```ts
// 1) Promote/insert the existing host as the master's local node.
const local = await prisma.node.upsert({
  where: { id: process.env.INFINIBAY_LOCAL_NODE_ID ?? (await firstOrSyntheticNode()).id },
  update: { role: 'master', status: 'online', address: '127.0.0.1', lastHeartbeat: new Date(), epoch: { increment: 1 } },
  create: { name: hostname(), role: 'master', status: 'online', address: '127.0.0.1', epoch: 1,
            cpuFlags: detectCpuFlags(), ram: totalRamMB(), cores: cpuCount(), currentRaid: 'none' }
});
// 1b) Single-NIC default: VTEP = mgmt IP (Onboarding owns multi-NIC population).
await prisma.nodeUnderlay.upsert({
  where: { nodeId: local.id },
  update: {}, create: { nodeId: local.id, vtepIp: '127.0.0.1', mgmtIp: '127.0.0.1' }
});
// 2) Adopt every orphan VM onto the local node BEFORE any node-scoped reconcile runs.
//    Set desiredState from current observed status so the new drift logic doesn't "correct" a steady VM.
await prisma.$executeRaw`
  UPDATE "Machine"
     SET "nodeId" = ${local.id},
         "desiredState" = CASE WHEN "status" = 'running' THEN 'running' ELSE 'stopped' END
   WHERE "nodeId" IS NULL`;
```

Backfill order matters: it runs **before** the first node-scoped reconcile so no VM is left `nodeId=null` (invisible to every agent), and `desiredState` is seeded from observed `status` so the very first reconcile sees zero spurious drift. The migration is gated to `role='master'` installs; `setup.sh --role node` is schema-less provisioning (no DB). The result: a no-downtime, no-data-touch upgrade for the existing fleet, multi-node-safe from the first boot, and — per ADR-5 — a master outage during or after the upgrade never kills a running desktop.

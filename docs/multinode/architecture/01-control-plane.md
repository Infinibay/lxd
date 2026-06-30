## Control Plane & Node Agent

This section specifies the master coordinator and the Node Agent: their process model, the master↔agent RPC contract, command-delivery semantics, the `NodeDispatcher`, the node-scoped reconciliation loop (fixes **G0**), control-plane HA, and the agent state machine + **agent-push** heartbeat/lease. Storage relocation (`VMStorageMigrationAdapter`), live-migration QMP plumbing, onboarding/pairing + CA, the self-fence *kill action* (Observability §3), and the installer are owned by their own sections and referenced here. This revision resolves the cross-section contradictions reviewers flagged: heartbeat is **push** everywhere, the outbox is **one** model (`CommandOutbox`), idempotency keys are **per-command-instance**, self-fence is **decoupled from control-plane reachability** and **storage-tier-gated**, and the agent→master direction is **cert-scoped**.

### 0. Shared timing & topology constants (single source of truth)

All sections reference these; nobody redefines them. Values are owned here and consumed by Observability/Scheduling/Data-Model.

```ts
// @infinibay/shared/cluster-constants.ts — the ONLY definition site
export const HEARTBEAT_INTERVAL_MS   = 5_000;   // agent→master lease renewal cadence
export const LEASE_TTL_MS            = 15_000;  // lease lifetime granted per renewal
export const AGENT_SELFFENCE_AT_MS   = 12_000;  // agent self-fences Tier-S VMs past this (see §7.3)
export const MASTER_DECLARE_DEAD_MS  = 20_000;  // master flips Node→offline + may evacuate
export const NODE_STALE_AFTER_MS     = 15_000;  // nodeHealth staleness (owner: Observability §1)
// Safety inequality (proven in §7.3): AGENT_SELFFENCE_AT_MS < MASTER_DECLARE_DEAD_MS,
// with margin ≥ HEARTBEAT_INTERVAL_MS so a fenced node always SIGKILLs before the master starts it elsewhere.
```

The legacy Control-Plane figures (`HEARTBEAT_INTERVAL≈15s`, `MISS_LIMIT×3≈45s`) are **deleted**; they violated the ≤20s detection SLO and the fence margin.

### 1. Process model

The Node Agent is the **existing backend binary booted in agent mode** (`INFINIBAY_ROLE=agent`), not a new daemon. Today `InfinizationService.ts:115` constructs `new Infinization({...})` in-process; the agent *is* that same process minus GraphQL/Apollo and minus the Prisma-backed coordinator surface. One build, one `@infinibay/infinization` tree, one set of `diskDir`/`qmpSocketDir`/`pidfileDir` semantics (`InfinizationService.ts:27-33`).

```
                  ┌─ master replicas (INFINIBAY_ROLE=master) × N behind LB ───┐
                  │ Apollo/GraphQL · Prisma → Postgres · NodeDispatcher        │
                  │ leader/sharded crons · CA(leader-gated) · local Infiniz.   │
                  └───────────────┬──────────────────────────────────────────┘
                       mTLS gRPC  │ (NodeAgent service)         ▲ agent→master push
                  ┌───────────────▼──────────── agent (ROLE=agent) ───────────┐
                  │ gRPC server · Infinization({nodeId}) · NO Apollo · NO Prisma│
                  │ local /proc+pidfile reconcile scoped to own nodeId         │
                  │ local lease watchdog (push renew) — see §7                 │
                  └───────────────────────────────────────────────────────────┘
```

The agent does **NOT** hold a Prisma client. `Infinization` requires `prismaClient` (`lifecycle.types.ts:677`); a compute node has no DB. We inject a **`RpcDatabaseAdapter`** that proxies to the master (the interface already exists, `sync.types.ts:71`), so `findRunningVMs`/`findMachineByInternalName`/`updateMachineStatus` travel to the master. The master is the single writer; the agent never mutates the DB except through this proxy. **Exception (critical):** the self-fence enumeration path is **local-only** and never touches this proxy (§7.3) — it must work precisely when the master is unreachable.

> **ADR-CP1 — Agent has no local DB; uses an RPC-backed, cert-scoped DatabaseAdapter.**
> **Decision:** the agent's `Infinization` is constructed with `RpcDatabaseAdapter`. **Rationale:** preserves single-writer Postgres (no multi-master, plan §1.1) and reuses the library verbatim. **Alternatives rejected:** (a) local SQLite → split-brain on `Machine.status`; (b) direct agent→Postgres → re-opens **G0**. **Consequences:** (1) every DB-backed reconcile read is a round-trip, shrunk by node scoping (§5) and fail-closed on error (`PrismaAdapter.ts:380-392`); (2) **DB-backed reconcile is NOT usable during a partition** — therefore the destructive self-fence path uses a separate local-pidfile enumeration (§7.3); (3) the master, not the agent, is the trust boundary for *what the agent may read/write* — enforced by ADR-CP5.

### 2. RPC transport — ADR

> **ADR-CP2 — mTLS gRPC for master↔agent.**
> **Decision:** gRPC/HTTP-2 with mutual TLS; CA owned by master (plan §3.4). **Rationale:** native streaming for `exportDisk`/`importDisk` progress and `query-migrate` polling; typed `.proto` IDL gives versioned stubs; per-RPC deadlines/cancellation for migration cancel. **Alternatives rejected:** JSON-RPC-over-HTTPS (loses streaming + IDL compat); we still expose **one** plain-HTTPS endpoint `POST /node/join` (onboarding) because the agent has no client cert at join. **Consequences:** add gRPC + `protoc`; mTLS handshake pins `Node.fingerprint` (TOFU). Every RPC carries `api_version` (semver-major int); a major mismatch → `FAILED_PRECONDITION` so a stale agent cannot drive a newer master.

### 3. Method surface (`service NodeAgent`) + bidirectional node-scoping

```proto
service NodeAgent {
  // master→agent lifecycle — every method enforces spec.node_id == self.nodeId
  rpc CreateVM (CreateVMReq) returns (OpResult);
  rpc Start    (VmRef)       returns (OpResult);
  rpc Stop     (StopReq)     returns (OpResult);
  rpc Reboot   (VmRef)       returns (OpResult);
  rpc Delete   (VmRef)       returns (OpResult);
  rpc GetStatus(VmRef)       returns (VmStatus);
  rpc ListManaged(Empty)     returns (ManagedList);     // node-scoped reconcile feed
  rpc GetConsoleInfo(VmRef)  returns (ConsoleInfo);
  rpc AttachDisk(DiskOpReq)  returns (OpResult);
  rpc DetachDisk(DiskOpReq)  returns (OpResult);
  rpc PushPerVmSecret(PerVmKey) returns (OpResult);      // JIT HMAC key (see §9, not master secret)
  // agent→master push (liveness + drift) — see §7
  rpc Heartbeat(HeartbeatPush) returns (HeartbeatAck);  // agent-initiated; renews lease
  // storage/migration seams (impl owned by storage / migration sections)
  rpc ExportDisk(ExportReq)  returns (stream Chunk);
  rpc ImportDisk(stream Chunk) returns (OpResult);
  rpc PrepareIncoming(IncomingReq) returns (IncomingEndpoint);
  rpc StartLiveMigration(LiveReq)  returns (stream MigrateProgress);
  rpc CancelMigration(VmRef)       returns (OpResult);
}

message OpResult {
  string command_id = 1;                       // == CommandOutbox.id (per-instance, §4)
  enum Outcome { APPLIED = 0; ALREADY_APPLIED = 1; REJECTED = 2; }
  Outcome outcome = 2;
  string vm_status = 3;
  string error = 4;
}
```

**ADR-CP5 (new) — the master is a node-scoped facade in BOTH directions; the cert is the only authority.** ADR-CP1 routes all agent DB access through `RpcDatabaseAdapter`, and the heartbeat carries `vms[]`. Reviewers correctly noted the master→agent direction is scoped (`spec.node_id == self.nodeId`) but nothing scoped the **agent→master** direction — a single compromised agent could read the whole `Machine` table or flip a peer's VM to `off`.

> **Decision:** the master derives `nodeId := verifiedClientCert.CN` on **every** agent-originated call (RPC DB proxy *and* heartbeat) and ignores any agent-supplied `nodeId`. The proxy is a node-scoped facade, not a transparent Prisma passthrough:
> ```ts
> class MasterRpcFacade {
>   constructor(private certNodeId: string, private prisma: PrismaClient) {}
>   async findRunningVMs()            { return this.prisma.machine.findMany({ where:{ nodeId:this.certNodeId, status:'running' }}); }
>   async updateMachineStatus(id,s)   {
>     const m = await this.prisma.machine.findUnique({ where:{id}, select:{nodeId:true}});
>     if (!m || m.nodeId !== this.certNodeId) throw new RpcError('FORBIDDEN_FOREIGN_MACHINE');
>     return this.prisma.machine.update({ where:{id}, data:{ observedStatus:s }});  // observed, never desired
>   }
> }
> ```
> Heartbeat ingest likewise rejects any `vms[].machineId` whose `Machine.nodeId != certNodeId`, and an agent can only refresh **its own** `Node.lastHeartbeat`/lease epoch — it cannot keep a dead peer fresh to block fencing. **Rationale:** the "master is the sole RBAC point" claim only holds if the master actually scopes proxied reads/writes to the caller's identity. **Consequences:** the blast radius of a compromised agent is its own VMs (matches the security ADR-S3 promise); a stolen client cert cannot enumerate or mutate the fleet.

### 4. Delivery semantics — ONE transactional outbox (`CommandOutbox`), idempotent apply

There is **one** master→agent command table: **`CommandOutbox`**, owned by the Data-Model section. The previously-defined `NodeCommand` schema is **deleted** — `CommandOutbox` strictly dominates it (monotonic `seq` for per-machine FIFO, `leaseOwner`/`leaseExpiry`, `expectVersion`, and a terminal `dead` state). This section defines only how the dispatcher and agent dedup consume it.

```prisma
// owner: Data-Model. Reproduced for reference; do not redefine.
model CommandOutbox {
  id             String   @id @default(uuid())   // == wire command_id == dedup key (PER-INSTANCE)
  seq            BigInt   @default(autoincrement())
  nodeId         String
  machineId      String?
  method         String
  payload        Json
  idempotencyKey String   @unique                // identity-of-intent for ONCE-EVER ops only (see below)
  expectVersion  Int?                             // optimistic guard vs Machine.version
  state          String   @default("pending")    // pending|leased|dispatched|acked|failed|dead
  leaseOwner     String?
  leaseExpiry    DateTime?
  attempts       Int      @default(0)
  createdAt      DateTime @default(now())
  @@index([nodeId, state, seq])
}
```

**Write path.** A GraphQL mutation writes one `CommandOutbox(pending)` row in the **same transaction** as the desired-state `Machine` change (e.g. `desiredStatus='running'`). **Dispatch authority is the OpResult, and only the OpResult** — a dispatcher transitions the row `acked`/`failed`/`dead` on the agent's reply. Heartbeat ingest **must not** transition outbox rows; if a heartbeat observes a command's effect without an OpResult, that is *drift to reconcile*, not an ack (closes the dual-ack hole reviewers flagged; the rule is owned here and referenced by Data-Model).

**Idempotency key rule (decisive, was under-specified).** The wire `command_id` used for agent dedup is **the row `id` (a fresh UUID per command instance)** for *all* verbs, repeatable or not. The separate `idempotencyKey @unique` column is reserved **only for genuinely once-ever intents** and is content-addressed there: `createVM → hash(machineId,'create')` (so a duplicate create enqueue is rejected at insert time), and `ha-restart → hash(machineId, fenceEpoch)` (§6.3). **No repeatable verb (Start/Stop/Reboot/AttachDisk) ever uses a content-derived key** — doing so would make `start → stop → start` collide and the second start return `ALREADY_APPLIED` forever (a silently-dropped command). The Data-Model worked example is corrected to show `command_id = row.id` for Start/Stop and the content hash only on the create/ha-restart `idempotencyKey` column.

**Agent dedup.** A bounded LRU `command_id → OpResult`, journalled under `pidfileDir` so a restart still recognises in-flight replays. TTL is keyed off the *command instance* (safely shorter than the minimum gap between distinct user intents), not off outbox-pending lifetime. Because a long-offline node's rows may stay `pending` past any fixed TTL, **createVM must additionally be idempotent against LOCAL state** — `findMachineByInternalName(name, nodeId)` + pidfile presence under `pidfileDir` — so a re-apply after TTL expiry is a no-op regardless of cache contents. Separately, an outbox row may not remain `pending` to a node indefinitely: past `OUTBOX_PENDING_MAX` it transitions `dead` + alerts, so dedup-TTL and pending-lifetime are not unboundedly decoupled (bound owned by Data-Model).

**Concurrency model — pick ONE: sharded leader pumps.** We adopt SKIP-LOCKED-free **per-node-bucket leadership** (§6.2): each bucket has exactly one leader draining its nodes' rows in `seq` order, giving per-machine FIFO for free without a multi-dispatcher older-row scan. The `expectVersion` guard and the agent's optimistic lock (`PrismaAdapter.transitionVMStatus`, `PrismaAdapter.ts:699-814`) remain the last line of defence; the per-instance `command_id` is the first.

### 5. NodeDispatcher + node-scoped, migration-aware reconcile (fixes G0)

`NodeDispatcher` replaces every direct `getInfinization()` call site (`CreateMachineServiceV2`, `VMOperationsService`, `SnapshotServiceV2`, `QemuGuestAgentService`), resolving `Machine.nodeId → client` (local in-process fast-path when `nodeId == localNodeId`, else cached gRPC stub). Unchanged from the prior draft.

**G0 fix.** `findRunningVMs` filters only `status:'running'` (`PrismaAdapter.ts:443`) and the orphan reaper kills any local PID with no DB match (`HealthMonitor.ts:543-554`). We scope **both** axes to the node:

- `InfinizationConfig.nodeId: string` (`lifecycle.types.ts:671`), threaded into the adapter.
- `findRunningVMs(nodeId?)`, `findMachinesByStatuses(…, nodeId?)`, `findMachineByInternalName(name, nodeId?)` add `where.nodeId` (`PrismaAdapter.ts:438,482,345`). A process mapping to a VM owned by another node is **never** an orphan to this host. Fail-closed preserved (`PrismaAdapter.ts:380-392`).
- The master's startup reconcilers (`InfinizationService.ts:140-174`) filter to the **local** node so they never reset a remote node's `backing_up` marker (`InfinizationService.ts:346-375`).

**Migration-aware reconcile (closes the mid-migration leak, high finding).** A VM in `prepareIncoming` runs a paused QEMU on the *target* while `Machine.nodeId` is still the *source* (flips at switchover, I3). Pure node-scoped reconcile sees it on neither node → leaked, un-reapable QEMU pinning the migration port/NBD export/destination disk. **Fix:** reconcile additionally consults non-terminal `MigrationJob` rows (owner: migration section) where this agent is `targetNodeId` *or* `sourceNodeId`:

```ts
// agent reconcile, per tick AND on restart
const jobs = await rpc.findNonTerminalMigrationJobsFor(self.nodeId); // target OR source
for (const j of jobs) reconcileMigrationLeg(j); // match local QEMU to j.phase + j.fenceToken
// on restart: if self is TARGET and j.phase < SWITCHOVER → tear down incoming QEMU,
//             release port/NBD/dest-disk, let master re-drive from clean state (idempotent, I4).
//             if self is SOURCE and j.phase < SWITCHOVER → keep source QEMU (still authoritative).
```

This is **Phase 0** and lands before any second node exists. The `MigrationJob` phase/fence-token contract is owned by the migration section; this section only states that reconcile *consumes* it.

### 6. Control-plane HA — N replicas, sharded leadership, held sessions, CA placement

Postgres is the source of truth, so the master runs as **N stateless replicas behind a LB** for GraphQL/query availability. The hazard is the cron set in `crons/all.ts:18` plus the command pump and reconcile loop, which would multi-fire under N replicas.

#### 6.1 Per-singleton advisory-lock leadership
> **ADR-CP3 — Leader election via Postgres advisory locks, with held sessions for long ops.**
> **Decision:** gate short, idempotent singletons (status cron, pool refill, metrics watchdog) behind `pg_try_advisory_lock(key)` re-checked each tick. **Rationale:** no new infra; auto-release on session death. **Refinement (was a blocker):** a *per-tick* acquire/release is acceptable only for short idempotent jobs. **Fencing/evacuation is multi-step and minutes-long and must NOT run under a per-tick lock** — see §6.3. **Consequences:** one advisory key per singleton class; split-second double-run at failover is tolerated for the short jobs because each is idempotent (G0 makes the reaper safe; the command pump is idempotent via §4).

#### 6.2 Sharded command pumps (removes the single-leader bottleneck)
A single global pump draining every node's outbox lands all dispatch on one replica at 1000 VMs. Instead, shard by node bucket: `bucket = hash(nodeId) mod K`, one advisory key per bucket. Up to K replicas each lead a **disjoint** slice of nodes and drain in parallel, bounding blast radius if one replica stalls. Because heartbeat is now **push** (§7), the leader does no serial fan-out polling at all — it only consumes pushed frames and runs the miss-detector.

#### 6.3 Crash-safe HA-restart / evacuation (was a blocker: double-run on two healthy nodes)
Evacuation is non-idempotent and long (`fence → confirm-dead → place → create+start`). It must NOT be a direct dispatch and must NOT run under a per-tick lock. Design:

- **Held-leadership session.** A single replica acquires a dedicated `FENCE_LEADER` advisory lock and **holds it for the duration** of an evacuation. Loss of the lock (its Postgres session died) **aborts in-flight side effects** before any start RPC commits — a new leader resumes from the journal, never restarts the plan.
- **Persisted state machine.** Each evacuation is a `FenceAction` row + per-VM `evacuation` rows (owner: Data-Model / Observability for the action semantics), with a monotonic `fenceEpoch` on `Node.liveness`. A new leader **resumes** the persisted plan; it does not re-run `chooseNodeForMachine` for a VM already placed.
- **Route every HA-restart through `CommandOutbox`** with deterministic `idempotencyKey = hash(machineId, fenceEpoch)`. Two interleaving would-be leaders therefore produce the *same* key → the second enqueue is deduped at the `@unique` constraint; a start carrying a **stale `fenceEpoch`** is rejected by the agent (`REJECTED`, epoch superseded). This makes "two leaders each start the dead-node VM on a different live target" impossible — the shared-storage / duplicate-L2-identity double-run window is closed.
- **Per-step idempotency**, exactly as `MigrationJob` already is. The fence-decision/placement policy is owned by Observability §4 (STONITH) and Scheduling; this section owns the *delivery* (outbox + held leadership + epoch key) that makes it crash-safe.

#### 6.4 CA under N replicas (was a blocker vs single-CA-key invariant)
`ca.key` lives on **one designated host only** (`/var/lib/infinibay/pki/ca.key`, root 0600, never in DB — onboarding §7 / Deployment ADR-D4). Under N replicas: **signing operations are leader-gated** — `approveNode`/`rotateNodeCert` reuse the §6.1 advisory leader; a replica without `ca.key` that receives the GraphQL mutation **proxies the signing call to the CA leader** (or rejects with `RETRY_ON_LEADER`). All replicas share **one master server cert** issued from the CA with `SAN = LB VIP`, so agent server-cert pinning holds across replicas. State (owner: onboarding/deployment): `ca.key` physical residence = the CA-leader host; non-leader replicas never hold it.

#### 6.5 Console gateway under N replicas — cross-reference
The console data-path proxy (SPICE/VNC) and its `sessionToken → (node,port,ticket)` map are **owned by Networking (ADR-N3)**. Reconciled requirement this section imposes on them: the console proxy must run as a **separate horizontally-scaled tier, not on the GraphQL event loop**, and session affinity must be explicit — either persist the session map in Postgres/Redis (any replica serves the `wss://` upgrade) or encode the owning worker in `sessionToken` for LB sticky routing. Deployment notes the LB affinity requirement. (Out of this section's scope beyond stating the constraint.)

### 7. Agent state machine + AGENT-PUSH heartbeat/lease

The agent lifecycle (distinct from per-VM status):

```
   ┌──────────┐ join+approve ┌──────────┐ mTLS up ┌────────┐ push renews lease
   │ UNPAIRED ├─────────────▶│ APPROVED ├────────▶│ ONLINE │◀────────────────┐
   └──────────┘ (onboarding) └──────────┘         └───┬────┘                  │
                                  ▲   master misses heartbeats │ (push)        │
                                  │      ┌─────────┐           │               │
                    reconnect/mTLS└──────┤ OFFLINE │◀──────────┘               │
                                         └────┬────┘   agent keeps renewing ───┘
                          decommissionNode    ▼
                                         ┌───────────────┐
                                         │ DECOMMISSIONED│
                                         └───────────────┘
```

These map onto `Node.status` (`pending|approved|online|offline|rejected|decommissioned`, plan §2).

#### 7.1 Heartbeat is AGENT-PUSH (was contradicted across sections; resolved to push)
> **ADR-CP4 (REWRITTEN) — Agent-push lease-renewal heartbeat; master-pull REJECTED.**
> **Decision:** the **agent** pushes `Heartbeat(HeartbeatPush)` to the master every `HEARTBEAT_INTERVAL_MS` (5s); the master returns `HeartbeatAck{ leaseEpoch, leaseExpiry }`, renewing a locally-armed lease deadline on the agent. **Rationale:** the self-fencing watchdog (§7.3) and the no-double-run safety proof require an *agent-side* renew-by deadline to miss — a pull model gives the agent no renewal event, so the watchdog can never arm and a partitioned-but-alive node on shared storage could double-write. Push also scales as fan-**in** (cheap per-node writes) rather than one leader's serial O(nodes) fan-out, and survives a master-side partition gracefully. **Alternatives rejected:** master-pull (ADR-CP4 original) — incompatible with the lease watchdog, blind during master partition, serial bottleneck. **Consequences:** the master runs a **miss-detector**, not a poller; the `command_pump` leader (§6.2) consumes pushed frames; detection latency is bounded by `MASTER_DECLARE_DEAD_MS` (20s).

**Two cadences, one not the other (write-amplification fix).** The high-frequency lease renewal is **tiny** — `{nodeId(from cert), leaseEpoch}` — and the master does a single `Node.lastHeartbeat/epoch` write per node per beat (20 writes/5s, trivial). The heavier `vms[]` drift payload + capacity rides a **slower 15–30s cadence** (or only-on-change), and the master **diffs `vms[]` against DB and UPDATEs only rows that actually changed**, skipping the common no-drift case so steady state is read-only. Live cpu/ram/rss metrics are **not persisted to Postgres** — they stay in master memory and are exposed to Prometheus directly (retention is Prometheus/TSDB, owned by Observability §2). This removes the 200-VM-eval/s + 50-row-UPDATE/5s hotspot reviewers flagged.

```ts
interface HeartbeatPush {            // nodeId is IGNORED if present — master uses cert CN (ADR-CP5)
  leaseEpoch: number
  agentVersion: string; apiVersion: number
  // slow-cadence fields, optional on fast beats:
  capacity?: { freeCores: number; freeRamMB: number; freeDiskGB: number }
  vms?: Array<{ machineId: string; status: string; qemuPid: number | null }>  // drift feed
  clockUnixMs: number               // skew detection for migration timeouts
}
interface HeartbeatAck { leaseEpoch: number; leaseExpiryUnixMs: number }
```

`nodeHealth`/`NODE_STALE_AFTER_MS` (the `lastHeartbeat`-based staleness function and the `status∈{approved,online}` schedulable predicate) has a **single owner: Observability §1** (which holds the concrete code). This section, Scheduling, and Data-Model reference it and do not redefine it. The one real semantic question — *is `status='approved'` (paired, pre-first-heartbeat) schedulable?* — is answered there (decision: **not** schedulable until first heartbeat).

#### 7.2 Single-host master node liveness (was broken by staleness)
The master's in-process Infinization never sends an RPC heartbeat, so the master-local `Node` would go stale after `NODE_STALE_AFTER_MS` and `NodePlacementService` would exclude it → a single-host install could place nothing. **Owner: this section.** The §6.1 leader-gated loop writes `lastHeartbeat = now()` + bumps the lease for the master-local node every `HEARTBEAT_INTERVAL_MS` from the in-process agent's own `/proc` view (treated as a zero-network "push from self"). Equivalently a node with `role='master'`/`address='127.0.0.1'` is liveness-exempt. Added to the single-host regression checklist.

#### 7.3 Self-fence — DECOUPLED from control-plane reachability, storage-tier-gated, local-only
The destructive self-fence *kill action* is owned by **Observability §3**; this section owns its **trigger discipline and enumeration source**, which reviewers correctly called fleet-fatal as previously specified. Three hard rules:

1. **Never self-fence on bare lease timeout / master-unreachable alone.** A master restart, leader-election gap, LB blip, or Postgres pause >12s must **not** make every node SIGKILL every desktop. Self-fence fires only when the node would otherwise risk a **shared-storage double-write**, i.e. it is gated to **Tier-S (shared-storage) VMs**. **Tier-L (local-disk) VMs keep running through a control-plane outage** — they cannot be double-run on shared media, so killing them is pure availability loss. This directly reconciles the partition policy: ADR-CP4's "partitioned-but-alive agent keeps its VMs running" is now **true for Tier-L** and **conditionally fenced for Tier-S only**.
2. **Self-fence is positively-confirmed where possible, lease-timeout-only as last resort behind quorum.** Preferred trigger: the node positively confirms it lost a contested resource — **shared-storage lock revoked / lease epoch superseded** (the storage tier reports this without master mediation). Bare lease-timeout self-fence (Tier-S) is enabled **only once the master HA quorum exists** (multiple coordinators + replicated/clustered Postgres). Until that quorum ships, lease-based Tier-S self-fence is **disabled** (a single-Postgres control plane must never be a single point of total data loss). The timing proof (`AGENT_SELFFENCE_AT_MS=12s < MASTER_DECLARE_DEAD_MS=20s`) must hold **across a master leader failover**, not just a clean single-master run — which is why it is gated on quorum.
3. **Enumeration is LOCAL-ONLY — zero master dependency.** The fence trigger *is* master-unreachability, so the RPC-backed `findRunningVMs` cannot answer and per ADR-CP1 fails closed (kills nothing). The self-fence path therefore **scans `/proc` + `pidfileDir` for QEMU PIDs the agent itself launched** (`InfinizationService.ts:27-33` — the agent owns its pidfiles), tagging each as Tier-S/Tier-L from local launch metadata, and SIGKILLs **only the Tier-S set**. Because there is exactly one agent per host, every pidfile under `pidfileDir` is by construction this node's — no DB lookup is needed to know "mine." This local path is the fence's source of truth and is **explicitly distinct** from the DB-backed orphan-classification reaper (§5), which still fails closed on RPC/DB error. The two contracts no longer collide: *reaper fails closed on DB error* (orphan classification) vs *self-fence kills the local Tier-S pidfile set unconditionally on confirmed contention* (lease-loss).

### 8. Failure modes summary

| Failure | Detection | Recovery |
|---|---|---|
| Master crash mid-command | outbox row stuck `pending`/`leased`/`dispatched` | bucket-leader pump redelivers same `command_id`; agent dedup → `ALREADY_APPLIED` |
| Agent crash | pushed heartbeat stops → miss-detector at `MASTER_DECLARE_DEAD_MS` | on restart agent re-attaches local VMs (node-scoped + migration-aware §5); coordinator re-drives via outbox |
| Network partition, agent alive, **Tier-L VMs** | lease timeout | **VMs keep running**; node reads `offline`; no reap, no fence (§7.3) |
| Network partition, agent alive, **Tier-S VMs** | lease timeout **and** quorum present **and** storage lock revoked/epoch superseded | local-pidfile self-fence of Tier-S set only; master safe to restart elsewhere |
| Control-plane outage / Postgres pause >12s | lease timeout fleet-wide | **no mass kill** — Tier-L survives; Tier-S fence disabled pre-quorum (§7.3 rule 2) |
| Two would-be evacuation leaders | `FENCE_LEADER` advisory lock | only holder proceeds; epoch key `hash(machineId,fenceEpoch)` dedups; stale-epoch start `REJECTED` (§6.3) |
| Leader crash mid-evacuation | held-lock session death | new leader resumes persisted `FenceAction`/evac rows, does not re-place (§6.3) |
| Mid-migration target agent restart | non-terminal `MigrationJob` for self as target, pre-switchover | tear down incoming QEMU, free port/NBD/dest-disk, master re-drives (§5) |
| Compromised agent reads/writes peers | master cert-scoping (ADR-CP5) | `FORBIDDEN_FOREIGN_MACHINE`; agent confined to its own `nodeId` |
| Stale agent version | `api_version` major mismatch | `FAILED_PRECONDITION`; `Node.agentVersion` flags upgrade |
| DB unreachable from agent RPC adapter | adapter throws | orphan reaper fails **closed** (`PrismaAdapter.ts:380-392`); self-fence path unaffected (local-only) |

### 9. Cross-references (owned elsewhere; constraints stated, not designed here)
- **HMAC secret distribution (security finding).** The fleet-wide `INFINISERVICE_HMAC_MASTER_SECRET` **must never land on a compute node**. The master derives `HMAC(master, vmId)` and pushes only that **per-VM key** over the authenticated RPC (`PushPerVmSecret`, §3) to the node currently hosting the VM, and to the destination node JIT at migration. This keeps a compromised node's blast radius to its own VMs (ADR-S3) and satisfies migration without the master secret. Owner: **Security-RBAC + Deployment-Installer**; this section only carries the `PushPerVmSecret` RPC.
- **STONITH fence-decision/placement policy:** Observability §4 + Scheduling.
- **`MigrationJob` phase/fence-token state machine:** migration section (§5 consumes it).
- **`CommandOutbox`/`FenceAction`/`Node.liveness` schema + outbox pending bound:** Data-Model.
- **`nodeHealth`/`NODE_STALE_AFTER_MS`/schedulable predicate:** Observability §1 (single owner).
- **Console session affinity + proxy tier:** Networking ADR-N3 + Deployment.

**Files this section modifies:** `InfinizationService.ts:115` (pass `nodeId`), `PrismaAdapter.ts:345,438,482` (node scope), `NodeCapacity.ts:27-30` (heartbeat staleness, deferring the function to Observability §1), `crons/all.ts:18` (sharded leader gating), plus new `NodeDispatcher`, `RpcDatabaseAdapter`/`MasterRpcFacade` (cert-scoped), the agent local-pidfile self-fence path, and consumption of the Data-Model `CommandOutbox`/`FenceAction` (the old `NodeCommand` schema is removed).

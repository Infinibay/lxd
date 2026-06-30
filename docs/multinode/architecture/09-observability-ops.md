## Observability, Failure Handling & Day-2 Ops

Scope: keeping an N-node Infinibay cluster alive after Phase 1–2 ship. This subsystem owns the heartbeat that drives `Node.lastHeartbeat`/staleness (fixes **G3**), the `nodeHealth` liveness function (sole owner — other sections reference, do not redefine), the telemetry surface, and the part nobody likes to design until 2am: deciding a node is dead and restarting its VMs **without** double-running them. It depends on the *Node Agent + RPC* (mTLS channel, cert→`nodeId` identity), the *Onboarding* state machine (`Node.status`), *Data-Model* (schema), and *Migration* (`MigrationJob`) subsystems — referenced, not redesigned. Where a fix below mutates schema or another subsystem's contract, it is flagged **[cross-ref]**.

### 0. Shared constants (single source of truth)

All sections reference these; **Control-Plane §7/ADR-CP4 must delete its 15s/×3 values and import this block** [cross-ref]. The fencing proof is derived from them, so they live in one place (`packages/shared/src/clusterTiming.ts`).

```ts
export const HEARTBEAT_INTERVAL   = 5_000   // lease-renewal cadence (tiny frame, §1a)
export const DRIFT_INTERVAL       = 30_000  // heavy vms[]+metrics frame (§1b)
export const LEASE_TTL            = 15_000  // 3 missed beats
export const SAFETY_MARGIN        = 3_000
export const FENCE_MARGIN         = 5_000
export const AGENT_SELFFENCE_AT   = 12_000  // LEASE_TTL − SAFETY_MARGIN  (agent kills Tier-S VMs)
export const MASTER_DECLARE_DEAD  = 20_000  // LEASE_TTL + FENCE_MARGIN  (evacuation may begin)
export const NODE_STALE_AFTER_MS  = 15_000  // == LEASE_TTL
export const MAX_CLOCK_SKEW       = 2_000   // budgeted; nodes exceeding it are non-evacuable
export const MAX_HEARTBEAT_RTT    = 1_000
export const POST_FAILOVER_GRACE  = 15_000  // ≥ LEASE_TTL — new leader withholds dead-declare
```

### 1. Heartbeat protocol (fixes G3) — agent→PUSH, split into two cadences

Today health derives from `Node.updatedAt` (`NodeCapacity.ts:27`) with nothing refreshing it → every node reads `stale` after 5 min. The agent already runs a periodic loop; we piggyback heartbeat there and **push** master-ward over the agent RPC. Push (not master-poll) is **load-bearing, not a preference**: the self-fence watchdog (§3) can only arm if the agent has a *locally-known renew-by deadline*, which only an agent-initiated renewal provides; a pulled heartbeat gives the agent no renewal event to miss. **This resolves the cross-section contradiction: Control-Plane §7/ADR-CP4 must adopt push and have its leader *consume* pushed frames + run the miss-detector, not call `Heartbeat()`** [cross-ref]. See ADR-2.

To fix the DB write-amplification hotspot, the single frame is split into **two payloads on two cadences**:

```ts
// (1a) LIVENESS — tiny, every HEARTBEAT_INTERVAL (5s). Drives lease + staleness ONLY.
interface LeaseBeat {
  nodeId: string          // claimed; IGNORED for trust — master uses cert CN (§1c)
  epoch: number           // lease epoch the agent believes it holds (§3)
  seq: number             // monotonic; master drops out-of-order/dup
  bootId: string          // /proc/.../boot_id — detects silent reboot
  clockUnixMs: number     // agent wall clock at send — skew budget enforcement (§3e)
  kvmOk: boolean          // readiness gate
}
// (1b) DRIFT+METRICS — heavier, every DRIFT_INTERVAL (30s) or on local change event.
interface StateBeat {
  nodeId: string
  metrics: NodeMetrics                 // cpu/ram/disk/load/uptime
  vms: VmObservation[]                 // ONLY VMs whose nodeId == cert node (G0)
  agentVersion: string
}
interface VmObservation { machineId: string; qmpStatus: QMPVMStatus; qemuPid: number|null; rssMiB: number; cpuPct: number }
interface BeatResponse {
  epoch: number; leaseTtlMs: number    // authoritative — agent adopts
  desiredVersion?: string; drain?: boolean
  fenceable: boolean                   // master's view of this node's fence path (§3d)
}
```

**Ingest cost, three concerns / three stores** (fixes write-amplification):
- **Liveness** (1a): one `Node.lastHeartbeat`/`epoch` write per node per 5s (20 writes/5s at 20 nodes — trivial). No VM rows touched.
- **Live metrics**: held **in-memory** on the master and exported to Prometheus directly (§2); **not** persisted to Postgres. Prometheus is the retention layer.
- **Drift reconciliation** (1b): diff `vms[]` against DB, `UPDATE` only the rows that actually changed, skipping the common no-drift case so steady state is **read-only**. `qmpStatus` folds through the existing `QMP_TO_DB_STATUS_MAP` (`StateSync.ts:33`), generalizing `StateSync.syncState` to multi-node.

**(1c) Node-scoping on ingest (security — closes the lateral-movement hole).** The master derives `nodeId` from the **verified mTLS client cert CN on every agent-originated call** and treats the agent-supplied `nodeId`/`machineId` as untrusted. The ingest handler **rejects** any `LeaseBeat` whose claimed `nodeId != certNode`, and drops any `VmObservation` whose `Machine.nodeId != certNode`. The same rule binds the `RpcDatabaseAdapter` proxy: it is a **node-scoped facade**, not a transparent Prisma passthrough — `findMachineByInternalName`/`updateMachineStatus` are filtered to `nodeId = certNode`. This prevents a single compromised agent from reading the fleet's `Machine` table, flipping a peer's VM to `off`, or keeping a dead peer's `lastHeartbeat` fresh to block fencing. **[cross-ref: Agent-RPC/Security own the proxy implementation; this section mandates the ingest-side check.]**

**(1d) `nodeHealth` — sole owner, rewritten lease-aware.** A node in `status='approved'` (paired, pre-first-heartbeat) is **not schedulable** until its first heartbeat flips it `online`; `approved` exists only so the master accepts the first beat.

```ts
export function nodeHealth(n: { lastHeartbeat: Date|null; status: NodeStatus; address: string; role: string },
  now = new Date()): 'online'|'stale'|'offline' {
  if (n.role === 'master' && n.address === '127.0.0.1') return 'online'        // single-host exemption (§6e)
  if (n.status !== 'approved' && n.status !== 'online') return 'offline'
  if (!n.lastHeartbeat) return 'offline'
  return now.getTime() - n.lastHeartbeat.getTime() > NODE_STALE_AFTER_MS ? 'stale' : 'online'
}
```
`schedulable` (`NodeCapacity.ts:51`) requires `health==='online'` from `lastHeartbeat` (not `updatedAt`). **Other respecs of this function (Control-Plane §7, Data-Model, Scheduling) reference this definition.** [cross-ref]

### 2. Metrics / telemetry & health endpoints

Prometheus text exposition on each agent (`/metrics`, mTLS-gated) **and** an aggregated `/metrics` on the master. The master serves live node/VM metrics **from its in-memory ingest cache**, not by full-scanning `NodeMetrics`+VM rows on every scrape (the old design made Postgres a TSDB on the hot single-writer). Naming unchanged:

```
infinibay_node_up{node} / _cpu_used_ratio / _ram_avail_bytes / _disk_free_bytes{node,pool}
infinibay_node_last_heartbeat_age_seconds{node}   infinibay_node_lease_epoch{node}
infinibay_node_fenceable{node} 0|1                 # §3d — auto-evac eligibility
infinibay_vm_state{machine,node,state}             infinibay_vm_rss_bytes / _cpu_ratio
infinibay_migration_progress_ratio{job,machine,mode}
infinibay_migration_phase{job,phase} 1             infinibay_migration_queue_depth{node,role}  # §6c admission
infinibay_fence_total{node,method,result}          infinibay_clock_skew_ms{node}               # §3e
```

Three K8s-style probes: **liveness** (event loop + DB pool / agent alive); **readiness** (master: DB+CA loaded; agent: `kvmOk && status∈{approved,online}` — unready agents get no placements); **health** (aggregate). Reuse the existing `onCleanupAlert`/`emit('cleanup-alert')` seam (`HealthMonitor.ts`) as the bridge to the alert router (§5).

### 3. Node-failure detection, split-brain & fencing (STONITH)

**The hazard.** A missed heartbeat is ambiguous: node **dead** vs **alive-but-partitioned**, QEMU still writing qcow2. Restarting elsewhere while originals live → on shared storage, *concurrent writers / irreversible corruption*; on local storage, duplicate L2 identity. Invariant:

> **A VM may be (re)started on node B only after the cluster can PROVE it is not running on node A.**

**(a) Self-fence is conditioned on STORAGE TIER, not bare lease timeout (fixes the fleet-kill blocker).** The old "SIGKILL every local QEMU on lease loss" turned any control-plane hiccup — master restart, leader-failover gap, LB blip, Postgres pause >12s — into a **fleet-wide desktop kill**, inverting the HA goal. Corrected policy, per `Machine.storageTier`:

- **Tier-L (local qcow2 under `/var/lib/infinization/disks`):** a partitioned-but-alive node **keeps these VMs running**. They cannot be double-run on shared media, the master will **not** auto-restart them elsewhere (cold-copy needs the unreachable source disk anyway), so killing them is pure availability loss. The control-plane being unreachable **never** kills a Tier-L guest. This is the explicit reconciliation of **Control-Plane ADR-CP4's "partitioned node keeps its VMs"** with this section.
- **Tier-S (shared Ceph RBD / NFS):** self-fence applies, because double-write corrupts. On lease-renewal failure past `AGENT_SELFFENCE_AT`, the agent SIGKILLs **only its Tier-S** QEMU, then refuses new starts and marks itself `offline`. Self-fencing Tier-S is only enabled once the master HA quorum exists (multiple coordinators + replicated Postgres, Phase 5); **until then the master must not advertise `fenceable:true` and auto-evacuation of Tier-S is operator-gated** — a single-Postgres control plane may not arm a fleet self-destruct.

**(b) Self-fence enumeration is LOCAL-ONLY (fixes the fail-closed contradiction).** The trigger for self-fence is *master unreachable*, so the RPC-backed `findRunningVMs` cannot run and (per the reaper's fail-closed rule) must not. Self-fence therefore **never consults the DB**. Since there is exactly one agent per host, every QEMU under the agent's own `pidfileDir` is by construction this node's — the agent enumerates kill targets by scanning `/proc` + `pidfileDir` (the path already owned at infinization `HealthMonitor.ts:477`, the orphan-scan), filtered to Tier-S. We carve the two contracts explicitly:
  - **Orphan-classification path** (node healthy, deciding if a stray PID is an orphan): *fails closed* on DB error — never kills an unverified PID.
  - **Lease-loss path** (self-fence): kills Tier-S PIDs from **local pidfiles**, zero master dependency — *this local path is the fence's source of truth precisely because it has no RPC dependency.*

**(c) Hardware/softdog watchdog is MANDATORY to enable auto-evacuation (fixes the "no real fence" gap).** An in-process monotonic timer is never serviced by a *wedged-but-not-dead* agent (D-state I/O hang, paused container, kernel stall) — QEMU keeps running while the master declares dead and restarts elsewhere → split-brain. So a self-fence is only a fence if a `/dev/watchdog` (hardware or armed `softdog`) reboots the wedged box. The agent arms `/dev/watchdog` with timeout `< MASTER_DECLARE_DEAD`; the same heartbeat loop pets it.

**(d) `fenceable` gates automatic evacuation.** The master refuses to auto-evacuate any node lacking a **confirmed fence path** (BMC/PDU reachable, or armed watchdog). `Node.fenceable` is surfaced in inventory and `infinibay_node_fenceable`. When neither positive-fence nor watchdog exists, HA-restart is **operator-gated** (`confirmFence`), never automatic.

**(e) Margin budget is enforced across clock skew, RTT, and leader failover (fixes the timing-proof gap).** The two timers run on different clocks from different events, so the nominal 8s margin must be *budgeted*:
```
MASTER_DECLARE_DEAD − AGENT_SELFFENCE_AT  >  MAX_CLOCK_SKEW + MAX_HEARTBEAT_RTT
        8s                                >        2s       +      1s            ✓
```
The master computes `skew = |master_now − beat.clockUnixMs| − RTT/2` per node, exports `infinibay_clock_skew_ms`, and **refuses to auto-evacuate any node whose skew exceeds `MAX_CLOCK_SKEW` or is unknown** — it does not merely "detect" skew. **Post-failover grace:** a freshly elected leader inherits `lastHeartbeat` written by the dead leader (with an unknown offset), so it **withholds all dead-declarations for `POST_FAILOVER_GRACE ≥ LEASE_TTL`** after taking leadership, never evacuating on a predecessor's timestamps. The proof must hold across a leader failover, not just a clean single-master run.

**(f) Power/epoch backstop for Tier-S.** `FenceDriver` (IPMI/Redfish BMC or switched PDU) issues power-off, returns only on confirmed-down, audited to `infinibay_fence_total` + a `FenceAction` row. Where no BMC exists, the **epoch fencing token**: every Tier-S start carries `Node.epoch`; restart on B uses `epoch+1`; the storage layer enforces single-writer (Ceph RBD `exclusive-lock` + **blocklist of the old client**, or NFS lock break) so a stale A-side writer at `epoch` is rejected. A returning zombie sees its epoch superseded on next heartbeat and self-terminates.

```ts
type NodeLiveness = 'online'|'suspect'|'dead'|'fenced'|'evacuating'
interface FenceDriver { kind:'self'|'ipmi'|'redfish'|'pdu'; fence(nodeId:string):Promise<{confirmedDown:boolean;method:string;at:Date}> }
```
```
online ──miss>15s──▶ suspect ──miss>20s & skew-ok & fenceable──▶ dead
   ▲ heartbeat          │ heartbeat resumes                         │ master requests fence (epoch++)
   └────────────────────┘                                          ▼
                                              fenced ──policy──▶ evacuating ──done──▶ Node.status=offline
```
```mermaid
sequenceDiagram
  participant A as Agent compute-1
  participant M as Master (leader, held evac session)
  participant F as FenceDriver
  participant B as Agent compute-2
  Note over A,M: 5s LeaseBeats renew lease epoch=e
  A--xM: partition — beats stop
  Note over A: t=12s watchdog → SIGKILL local Tier-S QEMU; Tier-L keeps running; /dev/watchdog pets stop
  Note over M: t=20s + skew-ok + fenceable → liveness=dead
  M->>F: fence(compute-1)
  F-->>M: confirmedDown (ipmi) | epoch++→e+1 + RBD blocklist old client
  M->>B: enqueue createVM+start via CommandOutbox, idemKey=hash(machineId,e+1)
  B-->>M: started (rejects any stale-epoch start)
  Note over A: returns → epoch e superseded → self-terminate Tier-S; box rebooted by softdog if wedged
```

### 4. Automatic evacuation / HA-restart — crash-safe, exactly-once, resumable

The old "dispatch `createVM`+`start` on the target agent" was a **direct, non-idempotent** dispatch with no journal; combined with a per-tick advisory leadership lock (Control-Plane ADR-CP3), two interleaving tick-leaders — or a leader crashing mid-evacuation — could each run `chooseNodeForMachine` for the same dead-node VM and start it on **two healthy targets**. Three fixes:

1. **Held-leadership evacuation session.** Fencing/evacuation does **not** run under a per-tick `withLeadership`. The leader acquires a **session-scoped advisory lock** held for the whole plan; losing it (crash, demotion) **aborts in-flight side effects** and the next holder *resumes* from the journal rather than restarting. **[cross-ref: Control-Plane must expose a held-session leadership primitive distinct from its per-tick lock.]**
2. **Every HA-restart routes through `CommandOutbox`/`NodeCommand`** (the existing idempotency path) with `idempotencyKey = hash(machineId, fenceEpoch)`. Re-dispatch is deduped; a start carrying a **stale epoch is rejected** at the agent. No command is ever issued outside the outbox.
3. **The plan is a persisted state machine** so a new leader resumes, not restarts:

```prisma
// [cross-ref: Data-Model owns these — added to schema-evolution block, NOT introduced here ad hoc]
model FenceAction { id String @id @default(uuid()) nodeId String method String confirmedDown Boolean
  epoch Int  at DateTime @default(now()) actor String }                    // epoch == the lease grant that this fence supersedes
model Evacuation { id String @id @default(uuid()) machineId String fenceEpoch Int
  state EvacState  targetNodeId String? attempts Int @default(0) updatedAt DateTime @updatedAt }
enum  EvacState { planned placing dispatched confirmed failed abandoned }
// Node  += epoch Int @default(0), fenceable Boolean @default(false), liveness NodeLiveness
// Machine += desiredState MachineDesired @default(stopped), storageTier StorageTier  // §3a, §3-drift
```

Decision flow, only once `liveness=dead` **and** fence confirmed: select `machines where nodeId=dead, status∈{running,paused}, restart≠'never'`, order by `HaPolicy.priority`, and for each create an `Evacuation` row (`planned`), then drive it `placing→dispatched→confirmed` through the outbox. Each step is idempotent (like `MigrationJob` already is); a crash between any two states resumes deterministically because the `idempotencyKey` is a pure function of `(machineId, fenceEpoch)`.

```ts
interface HaPolicy { restart:'always'|'never'|'best-effort'; priority:number
  antiAffinityGroup?:string; maxRestartsPerHour:number /*default 3*/ }
```

**Durable desired-state (fixes the "intent vanishes when the outbox row is acked" gap).** Once a `Start` is acked its outbox row clears, leaving no record the VM *should* run — so a later single-VM QEMU death (observed→`off`) has nothing to diff against. We add `Machine.desiredState: running|stopped`, **set transactionally alongside enqueuing Start/Stop**, separate from observed `Machine.status`. **Drift = `status != desiredState` for a machine with no in-flight command.** The single-VM self-heal already exists — `HealthMonitor.handleCrashedVM` (`HealthMonitor.ts:883`) flips observed→`off`; the reconciler compares to `desiredState` to decide restart-vs-leave instead of inferring intent from an emptied outbox. Node-level HA-restart (this §) handles whole-node death; desiredState drift handles single-VM crash on a healthy node. **[cross-ref: Data-Model owns the column; this section defines drift semantics.]**

### 5. SLOs & alerting

| SLO | Target | Source |
|---|---|---|
| Node-failure detection latency | ≤ 20s (p99) | `last_heartbeat_age_seconds` |
| HA-restart of `restart=always` VM | ≤ 90s after fence | fence ts → `vm_state=running` |
| False-positive fence rate | 0 (correctness) | `fence_total{result="false"}` |
| Heartbeat delivery success | ≥ 99.9% / node / day | `seq` gaps |

Alerts (router fed by the `cleanup-alert` seam): `NodeStale`(age>15s, warn); `NodeDead`/`FenceFailed`(page — a fence that can't confirm blocks evacuation and **must not** be silently retried into a double-start); `NotFenceable`(node lost watchdog/BMC → auto-evac disabled, warn); `ClockSkewExceeded`(node non-evacuable); `MigrationStalled`(progress flat >5m); `MigrationQueueDeep`(admission backpressure, §6c); `CrashLoop`; `DiskPoolLow`(<10% → `unschedulable`); `VersionSkewExceeded`.

### 6. Day-2 operations

**(a) Draining.** `setNodeMaintenanceMode` extends to true drain: `drain:true` in `BeatResponse` → `schedulable=false`, then live-migrate `running` VMs off (Phase 4) or cold-migrate `restart=always` pool VMs, leaving `never` VMs for operator decision. Drain completes at 0 VMs.

**(b) Rolling upgrades & version skew.** Master first, agents second (master schema ≥ every agent). Agents may be **one minor behind**, never ahead; an out-of-range agent is quarantined (`unschedulable`, alert) but **never auto-fenced** — skew is operational, not a safety condition, and its VMs keep running. Per-node: drain → swap binary → readiness green → un-drain; never upgrade the master while a `MigrationJob.phase∈{copying,activating}`. **[cross-ref: Deployment-Installer §2 `run.sh join` must parse `--upgrade`, or document the re-provision command; §8 references it but the dispatcher case omits the flag.]**

**(c) Migration concurrency / admission (fixes the unbounded-drain blocker).** A drain or node-death evacuation enumerates ~50 VMs; firing all at once saturates source/target NICs+disks and runs N concurrent auto-converge migrations that throttle many guests. We add a **master-side migration scheduler** with explicit limits — `MAX_MIGRATIONS_PER_SOURCE`, `_PER_TARGET`, `_CLUSTER_WIDE` — plus an **aggregate per-node bandwidth budget** that divides `LiveTuning.maxBandwidthBytes` across in-flight jobs on that node. Drain/evac **enqueue** (largest-first ordering, already specified) and the scheduler **admits** against the limits rather than firing all at once. Queue depth is surfaced via `infinibay_migration_queue_depth`. **[cross-ref: Migration subsystem owns `MigrationJob`; this section specifies the admission/queue layer that gates it.]**

**(d) Decommission = positive fencing, not just CRL (fixes the rogue-node gap).** CRL only blocks *new* handshakes; a compromised/decommissioned agent will not voluntarily tear down its QEMU, and on Tier-S it keeps writing a qcow2 the master may re-home. `decommissionNode(id)` therefore drives the **same STONITH machinery as §3**: (1) **storage eviction** — Ceph RBD `exclusive-lock` blocklist of the node's client / NFS lock break; (2) **network quarantine** — drop the node's VTEP from every department FDB and revoke overlay membership; (3) **BMC/PDU power-fence** where available. Only after a confirmed fence is the node declared safely removed and its CRL entry issued. **[cross-ref: Networking owns FDB/VTEP eviction; Security owns CRL; this section owns the fence orchestration.]**

There are **two decommission paths**: a *graceful node-side* `./run.sh decommission` (cordon→drain→`lxc stop`, run on a live node — **[cross-ref: Deployment-Installer §8]**), and a **master-side dead-node runbook** `decommissionNode(id)` + `confirmFence(id)` that requires **no node shell** (the dead/partitioned node cannot run anything) and reuses §3's fence-confirm step before evacuation.

**(e) Single-host liveness (fixes "master is a 1-node cluster" breakage).** The master's in-process Infinization never sends an RPC heartbeat, so its local `Node.lastHeartbeat` would go stale at 15s and `NodePlacementService` would exclude it → a single-host install could place nothing. Owned here: `nodeHealth` **liveness-exempts** the local node (`role='master' && address='127.0.0.1'`, §1d), and additionally the leader-gated loop writes `lastHeartbeat=now()` for the local node each interval from the in-process `/proc` view. **Single-host regression checklist:** fresh install places a VM; placement still works 60s idle; master restart does not stale-exclude itself.

**(f) Control-plane backup/restore.** Compute nodes are stateless, so DR = protect the master: nightly `pg_dump` (incl. `Node`, `Machine`, `MigrationJob`, `FenceAction`, `Evacuation`) **plus** the mTLS **CA private key + signed agent certs**. Restore: stand up Postgres → restore CA → start master → agents reconnect on pinned certs and resume pushing heartbeats; the master rebuilds live VM state from the **first `StateBeat` from each agent** (`/proc` truth), touching no VM until its owning node reports in.

**(g) Runbooks (abbreviated).** *Node won't rejoin* → check epoch staleness (zombie) → re-pair if cert revoked. *Stuck `MigrationJob`* → `migrate_cancel` on source, VM stays on source, mark `rolled_back`. *Fence cannot confirm* → do **not** force-evacuate; operator confirms power-down, then `confirmFence(nodeId)` unblocks HA-restart.

### ADRs

**ADR-1 — Self-fence is storage-tier-conditional, watchdog-backed; control-plane reachability never kills a guest.**
*Decision:* on lease-renewal failure the agent self-fences **only Tier-S (shared-storage) VMs**, enumerated **locally** from `pidfileDir`, and only when a `/dev/watchdog` is armed and (Phase ≥5) an HA quorum exists; **Tier-L VMs keep running through any control-plane outage**. Master declares dead strictly later, gated on `fenceable` and a skew budget; shared-storage evacuation additionally requires BMC/epoch+blocklist confirmation.
*Rationale:* a single-Postgres control plane must not be a single point of *total* data loss — a transient master/LB/Postgres hiccup must not kill every desktop. Corruption only threatens shared media, so only Tier-S needs destructive fencing; local-disk desktops are safe to keep running and killing them is pure availability loss.
*Alternatives rejected:* (a) blanket self-fence on bare lease timeout → fleet-wide kill on any control-plane blip (the original blocker); (b) timeout-then-restart with no fence → split-brain corruption; (c) in-process timer with no watchdog → wedged agent never fences; (d) agent-quorum consensus → contradicts the centralized single-DB plan.
*Consequences:* Tier-S HA needs a watchdog **and** RBD/NFS single-writer locks **or** a BMC, plus the Phase-5 HA quorum before auto-fence is enabled; Tier-L VMs are unavailable (not destroyed) during a partition until the node returns; introduces a ~20s detection floor plus a post-failover grace.

**ADR-2 — One push heartbeat, split into a tiny lease beat + a slower state beat; cert is the only identity.**
*Decision:* agent→master **push**; `LeaseBeat` every 5s (lease + staleness), `StateBeat` every 30s (metrics + `vms[]` drift); master derives `nodeId` from the mTLS cert CN and rejects mismatched claims.
*Rationale:* push is *required* for the watchdog self-fence (the agent needs a locally-armed renew-by deadline); the split keeps the high-frequency path cheap and removes the Postgres-as-TSDB write amplification; cert-derived identity closes the cross-node lateral-movement hole.
*Alternatives rejected:* master-pull (Control-Plane ADR-CP4 original) — gives the agent no renewal to miss, so the self-fence cannot exist, and goes blind during a master-side partition; one fat combined frame at 5s — 200 VM-evals/s and 50-row UPDATE/node/5s on the single writer; trusting agent-supplied `nodeId` — a compromised agent reads/writes the whole fleet.
*Consequences:* **Control-Plane §7/ADR-CP4 is rewritten as rejected** [cross-ref]; liveness and drift now have independent cadences operators must reason about; the constants block (§0) is the single source for all derived timing.

**ADR-3 — HA-restart is exactly-once through the outbox under a held leadership session, opt-in per VM.**
*Decision:* every HA-restart enqueues through `CommandOutbox` with `idempotencyKey=hash(machineId, fenceEpoch)`; evacuation runs as a persisted `Evacuation` state machine under a *held* (not per-tick) leadership session; `HaPolicy.restart` defaults `never` for persistent VMs, `always` for pool VMs.
*Rationale:* a multi-step, minutes-long, non-idempotent evacuation cannot ride a per-tick advisory lock — two tick-leaders or a mid-plan crash would double-run on two healthy nodes; deterministic idempotency keys + a resumable journal make re-dispatch safe and stale-epoch starts rejectable.
*Alternatives rejected:* direct `createVM`+`start` dispatch (the original — no dedup, no resume); per-tick leadership for long ops (no stable leader → concurrent `chooseNodeForMachine`); restart-everything (license/identity conflicts) or restart-nothing (defeats VDI HA).
*Consequences:* requires a held-session leadership primitive from Control-Plane and the `Evacuation`/`FenceAction`/`desiredState` schema from Data-Model [cross-ref]; operators must classify VMs, the likely human error, surfaced in node-detail UI and the `error`-parked alert.

**ADR-4 — Per-VM HMAC keys, never the master secret, on compute nodes.** *(Cross-reference only — Security-RBAC owns this.)* This section's STONITH/decommission flow assumes the **Deployment-Installer model**: `INFINISERVICE_HMAC_MASTER_SECRET` never lands on a node; `HMAC(master, vmId)` is derived on the master and pushed JIT over mTLS to the node(s) hosting the VM (and to the destination at migration). A fenced/decommissioned node thus leaks at most its own VMs' keys, consistent with the blast-radius claim. **[cross-ref: Security-RBAC §1/§4 must delete the master-secret-on-every-node rows.]**

# Infinibay Multi-Node — Architecture Overview

> Status: **authoritative integrating spec.** This document sits above the 10 subsystem specs and is the single place that resolves cross-section conflicts. Where this overview and a subsystem disagree, **this document wins** and the subsystem is to be rewritten to match (the two such cases are called out explicitly in §1.1 and §6). Audience: implementers of Phases 0–5.

---

## 1. Executive summary & design principles

Infinibay today is a **single-host** VDI control plane: one Node/TS GraphQL backend imports `infinization` in-process and drives QEMU locally against one Postgres (`repos/backend`). The multi-node target keeps that backend as the **only** stateful brain and turns every hypervisor — including the master's own host — into a stateless **Node Agent** that hosts `infinization` and runs QEMU locally, reachable only over an authenticated, cert-pinned RPC.

The architecture is **one master control plane + N compute nodes**. The master owns the database, the scheduler, the CA, the migration coordinator, and the fencing authority. Compute nodes own nothing durable: they execute idempotent verbs and reconcile their *own* `/proc` against desired state scoped to their `nodeId`. This is the Nova/oVirt shape, right-sized: a centralized SoT with dumb, self-fencing executors — not a multi-master mesh.

**Design principles (load-bearing, referenced throughout):**

1. **Single source of truth.** Exactly one Postgres on the master. Nodes never hold authoritative state; they hold a cache and a PID table. "How does the DB work multi-node?" → *it does not distribute; it centralizes.* (DB HA is an optional Postgres replica, Phase 5.)
2. **Fail-closed.** Every ambiguous condition resolves to the safe action: an agent that cannot renew its lease **self-fences its VMs** before the master could ever schedule them elsewhere; the scheduler refuses to place rather than double-book; migration never deletes a source until the destination is proven authoritative (invariant I2).
3. **Idempotency everywhere.** Every command carries a per-command-instance key; the agent dedupes. Reconciliation is convergent, not edge-triggered. Replaying the outbox is always safe.
4. **Secure-by-default.** Three independent cryptographic planes (control mTLS, guest-command HMAC, overlay) that are never collapsed. No human types a shared secret. A compromised node's blast radius is **its own VMs only** — see §1.1.
5. **Keep single-host working, bit-for-bit.** `master is just a 1-node cluster`. `./run.sh` with no args still does `smart_default`. The master's local agent is a localhost fast-path. No regression for the existing deployment.

### 1.1 Cross-cutting resolution: the master HMAC secret never lands on a node

**Authoritative decision (overrides Security-RBAC §1/§4):** `INFINISERVICE_HMAC_MASTER_SECRET` lives **only** on the master, in the CA/coordinator's root-only EnvironmentFile (`setup.sh:401-409`). It is **never** distributed to compute nodes. Per-VM guest-command keys are derived on the master as `k_vm = HMAC(master_secret, vmId)` and shipped **just-in-time over the mTLS RPC** to the node(s) currently hosting that VM, and to the destination node at migration time. (Adopts Deployment-Installer §8.)

*Rationale:* placing the fleet-wide secret on every host (the withdrawn Security-RBAC §1 model) means one compromised node can forge host→guest commands for **the entire fleet**, directly contradicting that same document's ADR-S3 blast-radius promise ("a leaked guest secret forges for exactly one VM"). The migration requirement does not justify it — JIT-shipping `k_vm` to the destination solves migration with no loss of the one-VM blast radius. **Action:** delete the secrets-at-rest rows that put the master secret on nodes; fix the §1 rationale.

---

## 2. Target topology

```
            MANAGEMENT PLANE (mTLS, control RPC)            VM-TRAFFIC PLANE (overlay L2, VXLAN/Geneve)
 ┌──────────────────────────── MASTER (control plane) ───────────────────────────┐
 │  Postgres (single SoT)   Backend coordinator   Frontend/Harbor   mTLS root-CA  │
 │  Scheduler · MigrationCoordinator · FencingAuthority · CommandOutbox · Console  │
 │  proxy                                                                          │
 └───┬───────────────────────────┬───────────────────────────┬───────────────────┘
     │ mTLS RPC (agent-push HB)   │                           │
┌────▼──────────────┐   ┌─────────▼─────────┐       ┌─────────▼─────────┐
│ Node Agent (local)│   │ Node Agent (cmp-1)│  ...  │ Node Agent (cmp-N)│
│ infinization      │   │ infinization      │       │ infinization      │
│ QEMU/KVM · /proc  │   │ QEMU/KVM · /proc  │       │ QEMU/KVM · /proc  │
│ softdog watchdog  │   │ softdog watchdog  │       │ softdog watchdog  │
└────┬──────────────┘   └────┬──────────────┘       └────┬──────────────┘
     │                       │                            │
     └───────────────────────┴── overlay (vxlan-* TAPs) ─┘   ← VM east-west, dept = node-spanning VNI
                                  │
                          shared storage (Tier-S, optional)  ← Tier-L = local qcow2 + authenticated copy
```

Two physically/logically separable planes: **management** (master↔agent mTLS RPC, heartbeats, console tickets, DB proxy — never touches VM data) and **VM-traffic** (overlay segments carrying tenant L2, using a `vxlan-*` interface prefix so they are neither filtered as `vnet-*` TAPs nor accepted as DHCP, per Networking invariants). The base nftables forward chain stays `policy accept`; default-deny remains per-VM terminal `drop` (`NftablesService.ts:1051-1066`).

---

## 3. Component map — who owns what, and how they bind

| Component | Process / location | Owns | Binds to |
|---|---|---|---|
| **Coordinator** | backend on master | Scheduler, MigrationCoordinator, FencingAuthority, `NodeDispatcher`, `CommandOutbox` drain, console proxy, CA | Postgres (SoT); agents via `RemoteNodeClient` over mTLS |
| **Postgres** | master | Single SoT: `Node`, `Machine`, `MigrationJob`, `CommandOutbox`, audit | coordinator only (agents never touch DB directly; DB proxy via RPC if needed) |
| **CA / PKI** | master, created once in `setup.sh` | offline-rooted root-CA, master-server-cert, node-client-cert signing | onboarding flow; mTLS on every RPC |
| **Node Agent** | every hypervisor (incl. master) | hosts `infinization`; executes verbs (`create/start/stop/console/prepareIncoming/exportDisk/importDisk`); node-scoped reconcile; agent-push heartbeat + self-fence | coordinator (client), local `infinization`, softdog |
| **infinization** | in-process inside each agent | local QEMU spawn, QMP/QGA, qcow2 under `/var/lib/infinization/disks`, TAP/bridge/nftables/cgroups, `/proc` identity | agent process; constructed as `Infinization({nodeId})` (G0 fix) |
| **Installer (`lxd`)** | parent repo | role-aware deploy (`master`/`node`), `run.sh join`, secret generation, provisioning | LXD; writes `/etc/infinibay/role` |

**Key binding:** the backend stops importing `infinization` for VM ops and instead resolves `Machine.nodeId → Node Agent → RPC`. On the master host this resolves to the **local** agent (fast-path), preserving single-host behavior. The migration-era hybrid (Phase 1) lets the backend keep in-process `infinization` for the *local* node and use `RemoteNodeClient` only for remote nodes, dispatching on `Machine.nodeId === localNodeId`.

---

## 4. Key data flows

Timing constants are owned in **one** file `packages/shared/src/clusterTiming.ts` (Observability §0): `HEARTBEAT_INTERVAL=5s`, `LEASE_TTL=15s`, `AGENT_SELFFENCE_AT=12s`, `MASTER_DECLARE_DEAD=15s+`. The fencing proof requires `AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD`.

### (a) Create a VM — placement → outbox → agent → QEMU → status back

```
Operator   Coordinator      Scheduler        Postgres(SoT)   CommandOutbox   Agent(node)    infinization/QEMU
   │  create  │                 │                 │              │              │                 │
   │─────────▶│  score+reserve  │                 │              │              │                 │
   │          │────────────────▶│  atomic reserve capacity (tx)  │              │                 │
   │          │                 │──── write Machine{nodeId,status=SCHEDULING} ──▶│                 │
   │          │  same tx ──────────────────────────────────────▶ enqueue cmd{key, createVM} │     │
   │          │◀── tx commit ───┘                 │              │              │                 │
   │   ack    │                                   │   drain ─────┼─── RPC create(cmd,key,k_vm) ──▶│
   │◀─────────│                                   │              │              │── spawn QEMU ──▶│
   │          │                                   │              │              │◀── running ─────│
   │          │◀──────────── heartbeat vms[] includes vmId (observed=running) ──│                 │
   │          │── reconcile: desired==observed → Machine.status=RUNNING ───────▶│ (SoT)           │
```

Placement reservation and outbox enqueue are **one Postgres transaction** — no command exists without a durable reservation, and no reservation exists without a command (closes the double-book + lost-command races). The per-VM key `k_vm` rides the create RPC; it is the only secret the node receives.

### (b) Node join + double-verification pairing

```
New host          mDNS            Master(CA)            Operator(UI)
   │ run.sh join    │                 │                     │
   │── browse _infinibay-master._tcp ▶│                     │
   │◀── master addr + CA pin (OOB) ───│                     │
   │── join{hwInventory, CSR, SAS} ──▶│  create Node{status=PENDING}, show SAS-A
   │                                  │────── pendingNodes ─▶│  operator SEES SAS-A on node console
   │                                  │                      │  AND on UI → compares (human verify #1)
   │                                  │◀──── approveNode(nodeId, SAS-B) ── operator types/clicks
   │◀── signed node-client-cert ──────│  (master verifies SAS-B → bilateral)   (crypto verify #2)
   │   status=ONLINE after first HB   │
```

Double verification = the master proves itself via the OOB-pinned CA (no impostor master), and the operator confirms a short authentication string visible on **both** the joining node and the UI (no impostor node / MITM). Replaces the `setupNode` stub (`setup/resolver.ts:14-46`); `detectLocalHardware()` (`LocalNodeRegistrationService.ts:65-96`) becomes the node-side payload of `join`, not a direct DB write.

### (c) Cold migration (VM stopped)

```
Coordinator        Source Agent       Dest Agent        Postgres
  │ set Machine.migrationJobId, status=MIGRATING (sole writer while jobId set) │
  │── exportDisk ───▶│                    │                 │
  │                  │── stream qcow2 (authenticated peer channel) ──▶│ importDisk
  │── verify checksum match ◀────────────────────────────────────────│
  │  (I2: source intact until match)                                  │
  │── Machine.nodeId=dest, status=STOPPED, migrationJobId=null ──────▶│ (SoT)
  │── deleteDisk(source) ─▶│ (only now)   │                 │
```

Builds on `VMMigrationService.ts` and `VMStorageMigrationAdapter`. Tier-S (shared storage): reassign + relaunch, no copy. Tier-L: authenticated network copy + checksum.

### (d) Live migration (VM running)

```
Coordinator     Source Agent(QEMU)      Dest Agent(QEMU -incoming)
  │ CPU-compat check (Node.cpuFlags ∩) │
  │── prepareIncoming ─────────────────▶│ start QEMU -incoming
  │── ship k_vm to dest (JIT) ─────────▶│
  │── migrate(tcp:dest) ──▶│ QMP migrate │
  │   query-migrate (poll) │═══ RAM/dirty-pages ═══▶│
  │   converged?           │            │
  │── cont(dest) ──────────┼───────────▶│ (I1: single running writer at switchover)
  │── Machine.nodeId=dest, status=RUNNING ─────────▶ Postgres
  │── quit(source) ─▶│     │            │
```

Adds the QMP primitives infinization lacks today (`migrate`, `migrate-set-parameters`, `query-migrate`, `migrate_cancel`; `-incoming` in `QemuCommandBuilder`). `file.locking=on` (`QemuCommandBuilder.ts:232`) is the last-line backstop behind the state machine.

### (e) Node-failure detection → fence → HA-restart

```
Agent(node-2)    Master/FencingAuthority    Postgres        Other agents
  │ heartbeat... │                          │               │
  ✗ (partition / crash)                     │               │
  │ AGENT_SELFFENCE_AT=12s: cannot renew    │               │
  │   → softdog/self-fence kills its VMs ───┘ (no double-write to shared storage)
  │                          │ MASTER_DECLARE_DEAD≥15s:      │
  │                          │ Node.status=DOWN, epoch++ ───▶│
  │                          │ for HA VMs: reschedule on survivors via outbox
  │                          │──── createVM(epoch-checked) ──────────────▶│ (e)
```

The inequality `AGENT_SELFFENCE_AT (12s) < MASTER_DECLARE_DEAD (15s)` is the corruption-safety cornerstone: by the time the master restarts a VM elsewhere, the dead node has already stopped writing. A wedged (non-self-fencing) agent is killed by the hardware/softdog watchdog.

### (f) Heartbeat / state reconciliation

```
Agent ── every 5s ──▶ master:  renewLease{nodeId(from cert), epoch, vms[]:{vmId,state}}
master:  if epoch current → extend lease TTL=15s, upsert Node.lastHeartbeat
         reconcile desired(Machine) vs observed(vms[]) SCOPED to this nodeId:
            missing-and-desired  → re-enqueue start (outbox)
            present-and-undesired→ enqueue stop
            mismatch             → converge
agent:   every 30s (DRIFT) → heavy frame: full vms[] + metrics
```

---

## 5. Consistency & delivery model

- **Single Postgres SoT.** Desired state = `Machine`/`Node` rows; observed state = agent heartbeat `vms[]`. The master is the only writer of authoritative status; for any `Machine` with non-null `migrationJobId` it is the **sole** writer of `status`/`nodeId` (migration invariant).
- **Transactional outbox (`CommandOutbox`, the one and only model).** Commands are enqueued in the *same transaction* as the state change that motivates them, then drained to agents over RPC. At-least-once delivery + per-command-instance idempotency keys = effectively-once execution. The Control-Plane §4 `NodeCommand` model is **deleted**; `CommandOutbox` is canonical.
- **Node-scoped reconciliation (fixes G0).** `infinization.findRunningVMs` and the orphan-reaper filter by `nodeId`, not status alone, via `Infinization({nodeId})`. Without this, nodes cross-kill each other's VMs — the project's known data-loss landmine. This ships in **Phase 0**, before a second node exists.
- **Fencing & epoch leases.** Each node holds a time-bounded lease and a monotonic `epoch`. An agent that cannot renew self-fences (≤12s); the master declares dead and bumps `epoch` (≥15s). Every command and write is epoch-checked, so a revived old node's stale writes/commands are rejected. This is what makes shared-storage double-writes impossible after a partition.

---

## 6. ADR index

| ADR | Decision | Why | Owning section |
|---|---|---|---|
| **CP1** | Centralized Postgres SoT; nodes stateless | avoids multi-master; concentrates authority | Control-Plane / Data-Model |
| **CP2** | Node Agent hosts `infinization` in-process | reuse the lib unchanged; agent = infinization + auth transport | Control-Plane |
| **CP3** | One transactional `CommandOutbox`; `NodeCommand` deleted | effectively-once delivery, no lost commands | Data-Model |
| **CP4 (rewritten)** | **Heartbeat is agent-push lease-renewal, not master-pull** | fencing proof requires the *agent* to self-fence on renewal failure; master-pull has no agent-side renewal so a partitioned-alive node never self-fences | Observability §1 / §6 below |
| **S1** | Three independent crypto planes, never collapsed | each defends a distinct boundary | Security-RBAC |
| **S3 (corrected)** | **Master HMAC secret never on nodes; per-VM `k_vm` derived + shipped JIT** | one-VM blast radius; node compromise can't forge fleet-wide | Deployment-Installer §8 / §1.1 above |
| **O2** | Epoch leases + self-fence + softdog | no double-run / no shared-storage double-write | Observability |
| **ST1** | Two storage tiers, cluster-wide (Tier-S shared / Tier-L local+copy) | HA/fast-migrate vs zero-dependency default; reuses `storageMode` seam | Storage |
| **SC1** | Constraint-based scheduler with atomic reservation | kills double-book; enables spreading + overcommit + disk/GPU constraints | Scheduling |
| **MG1** | Master is sole migration coordinator; agents are idempotent verbs; I1/I2 invariants | single-writer + no-premature-delete safety | Migration |
| **N1** | Node-spanning L2 via authenticated overlay, `vxlan-*` prefix | departments span nodes without breaking TAP/DHCP/firewall invariants | Networking |
| **PKI1** | Single offline-rooted CA on master; SPKI + CA double-pin; SAS pairing | zero typed shared secrets; impostor/MITM-proof join | Onboarding-PKI |
| **D1** | Role-aware installer; master = 1-node cluster | single-host path preserved bit-for-bit | Deployment-Installer |
| **DB1 (new)** | infinization carries **no Prisma** on nodes (`RpcDatabaseAdapter`, ADR-CP1); recommended follow-up = invert the `DatabaseAdapter` port to actuator-shaped | decouple the lib from the `Machine` schema; close the ARCH-04 bypass; independently publishable/testable | Control-Plane / Data-Model / §6.2 |

### 6.1 Cross-cutting resolution: heartbeat direction (rewrites Control-Plane §7/ADR-CP4)

**Authoritative decision:** heartbeat is **agent-push lease-renewal**. The agent, every `HEARTBEAT_INTERVAL`, calls `renewLease(nodeId, epoch, vms[])`; the `nodeId` and `vms[]` are bound to the **mTLS client-cert identity** (an agent cannot renew or report for a node it is not). Control-Plane §7/ADR-CP4's "master-pull" wording is superseded and must be deleted. *Rationale:* the entire no-double-run / split-brain proof depends on the agent self-fencing when it **cannot renew** — a property that simply does not exist under master-pull (there is no agent-side renewal to fail). Keep the hardware/softdog watchdog so a wedged agent that stops pushing still self-fences.

### 6.2 Cross-cutting resolution: infinization decoupled from the DB (no Prisma on nodes)

This formalizes the question "should `infinization` stop managing the DB and only manage VMs?" — answered against the **verified** current code (independently re-checked 2026-06-29, see the README verification note).

**Verified current state.** `infinization` does **not** own a Prisma client: `prismaClient` is *injected and required* (`lifecycle.types.ts:677`; `Infinization.ts:154-161`), and a `DatabaseAdapter` port already exists (`sync.types.ts:71`). But the coupling is real and leaky: that port is **DB-shaped** (`updateMachineStatus`/`findRunningVMs`/`clearMachineConfiguration`…); `findRunningVMs` is **not node-scoped** (`PrismaAdapter.ts:443` — this *is* G0 at the port); and the core lifecycle reaches **around** the narrow port to the concrete `PrismaAdapter` (`transitionVMStatus`, `PrismaAdapter.ts:699-814`) — the ARCH-04 "core bypasses `DatabaseAdapter`" debt.

**Decision — two levels, only the first is on the multi-node critical path:**

1. **Ship (Phase 1) — no Prisma on nodes.** A compute node carries no database. `infinization` on a node is constructed with the **`RpcDatabaseAdapter`** (ADR-CP1, Control-Plane §1), so every DB-shaped call is proxied to the master, which is the **single writer** and the cert-scoped trust boundary (ADR-CP5). This already delivers the goal "infinization no longer touches Postgres on a node." G0 is enforced in the master facade (node-scope by the verified mTLS cert CN), not in the agent. The destructive **self-fence** path stays local-only and never uses the proxy (it must work when the master is unreachable — ADR-CP1/§7.3).

2. **Recommended follow-up (non-blocking) — invert the port.** Redefine `DatabaseAdapter` from DB-shaped *persistence verbs* to an actuator-shaped **desired-set-in / observation-events-out** contract, and route the bypassing lifecycle through it, so `infinization` holds **zero** knowledge of the `Machine` schema and the backend owns *all* status interpretation. This is the user's "`infinization` SOLO se encarga de las VMs" in full. Payoffs: G0 becomes **structural** (the lib only ever sees its own node's desired set, so there is nothing global to mis-scope), the ARCH-04 bypass and the SharedAlgorithms lib↔backend divergence die, and `infinization` becomes independently testable/publishable (no Prisma-shaped dependency). Cost: a focused refactor of `StateSync`/`HealthMonitor`/`EventHandler`. It is **not required to ship multi-node** — track it as a library-hygiene epic, ideally started opportunistically during the Phase 0 G0 work (pass the desired set in rather than re-querying) so the codebase moves toward the target instead of patching the old shape.

---

## 7. Glossary

- **Master / control plane** — the single host running Postgres, backend coordinator, frontend, and CA. Sole source of truth and sole command authority.
- **Node** — a compute hypervisor; a `Node` row in Postgres. Stateless executor. The master's own host is also a node (its local agent is a localhost fast-path).
- **Node Agent** — the daemon on every node that hosts `infinization`, runs QEMU locally, executes RPC verbs, reconciles node-scoped `/proc`, and pushes heartbeats.
- **Pool / storage tier** — Tier-S (shared storage, no-copy migration, HA) or Tier-L (node-local qcow2 + authenticated network copy). Cluster-wide attribute with per-node capability flags.
- **Golden image** — base disk (`GoldenImage.baseDiskPath`) from which per-VM qcow2 overlays are created; a node-local fact that may need cross-node replication.
- **Fence / epoch** — fencing = guaranteeing a suspect node stops writing (self-fence by lease expiry + softdog). Epoch = monotonic per-node counter bumped on death; stamps every command/write so stale revived nodes are rejected.
- **SAS code** — Short Authentication String shown on both the joining node and the UI during pairing; the human-verified half of double-verification.
- **Outbox (`CommandOutbox`)** — the transactional table where the master enqueues commands in the same tx as the motivating state change; drained to agents at-least-once with idempotency keys.
- **`k_vm`** — per-VM guest-command HMAC key, `HMAC(master_secret, vmId)`, derived on the master and shipped JIT to the hosting node. The master secret itself never leaves the master.

---

## 8. Phased delivery mapping & cross-cutting risks

| Phase | Goal | Owning subsystems | Gaps |
|---|---|---|---|
| **0 · Data safety** | multi-node is *non-destructive before it exists* | Data-Model (schema: `Node` cols, `MigrationJob`, `lastHeartbeat`), Control-Plane (`Infinization({nodeId})`, node-scoped reaper/reconcile), Observability (heartbeat→`lastHeartbeat`, staleness) | G0, G1, G3 |
| **1 · Node Agent + routing** | master drives a VM on a remote node | Control-Plane (Agent, RPC, `NodeDispatcher`/`RemoteNodeClient`, outbox), Scheduling (multi-node placement) | G2 |
| **2 · Onboarding + installer** | join a node in minutes, securely | Onboarding-PKI (mDNS, SAS pairing, CA), Deployment-Installer (`run.sh join`, `infinibay-node.yml`, roles), Security-RBAC (node verbs) | G6, G7, G8 |
| **3 · Cold migration** | move stopped VMs | Migration (cold seam), Storage (Tier-S/Tier-L copy + checksum), frontend node detail | G4 |
| **4 · Live migration** | move running VMs, no downtime | Migration (QMP live orchestration), infinization (`migrate`/`-incoming`/`query-migrate`), Networking (cross-host TAP swap), Scheduling (CPU-compat) | G5 |
| **5 · Hardening / HA** | production | Postgres replica (control-plane HA), shared-storage integration, cluster observability/metrics, cert revocation, adversarial tests | — |

**Minimum usable milestone:** end of **Phase 2** — `./run.sh join`, node appears PENDING, approve with SAS compare, master creates/starts/stops VMs on it and shows status.

**Cross-cutting risks carried across phases:**
- **Storage is the migration bottleneck.** Live-migrate without downtime is trivial on Tier-S, expensive on Tier-L (block-mirror large qcow2 over the wire). The seam supports both; the choice sizes Phases 3–4.
- **CPU compatibility for live migration.** `Node.cpuFlags` exists; policy (homogeneous CPUs vs a common baseline model) must be fixed before Phase 4.
- **Cross-node VM networking.** Departments spanning nodes need authenticated overlay L2 — designed in Networking, gated on the `vxlan-*` prefix + base-chain invariants.
- **Secret distribution (resolved, §1.1).** Master HMAC secret stays on the master; only `k_vm` ships JIT. Any subsystem still placing the master secret on nodes is a release blocker.
- **Heartbeat direction (resolved, §6.1).** Agent-push lease-renewal is mandatory; master-pull silently removes the only mechanism preventing post-partition double-writes.
- **G0 is blocking and cheap.** Node-scope the reaper in Phase 0 *even before a second node exists* — the failure mode is data-loss cross-kill.

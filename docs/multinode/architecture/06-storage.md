## Storage Architecture

Storage is the gating factor for migration speed and HA (plan §11). Infinibay today is single-node: every qcow2 lives under `/var/lib/infinibay/data/disks` (`setup.sh:305`), golden images at `GoldenImage.baseDiskPath` (schema `:624`), per-VM overlays tracked in `MachineConfiguration.diskPaths` (schema `:399-401`). Multi-node turns each of those paths into a *node-local* fact. This section defines the cluster storage tiers, the abstraction that selects between them, the qcow2/golden-image lifecycle across nodes, the **authenticated transport** that moves bytes between nodes, and integrity guarantees. It is consumed by **Migration** (cold/live), **Scheduling** (`NodePlacementService`), the **Node Agent** RPC (`exportDisk`/`importDisk`), and the **MigrationJob** state model — referenced, not designed, here.

### 1. Storage tiers — ADR

**Decision.** Support a two-tier model, selected *per cluster* (not per VM): **Tier-S (shared)** as the first-class HA/fast-migration path, **Tier-L (local + network copy)** as the zero-dependency default. Tier is a cluster-wide attribute, with per-node capability flags so a heterogeneous cluster degrades to the lowest common tier for any given VM pair.

**Rationale.** The existing seam already encodes exactly this binary: `VMMigrationService` distinguishes `storageMode: 'shared' | 'external'` and gates on `INFINIBAY_SHARED_STORAGE` (`VMMigrationService.ts:13-16,133-137`). Tier-S makes cold migration a metadata-only `nodeId` flip and makes live migration a RAM-only QEMU `migrate` (no `drive-mirror`); Tier-L keeps the LXD `dir` driver (`setup.sh:277-281`) and copies qcow2 over the authenticated transport defined in §7.

**Alternatives rejected.** (a) *Shared-only (mandate Ceph/NFS):* contradicts the "install a node in minutes" goal (plan §10 milestone) and the `dir` pool default. (b) *Local-only:* forecloses true live-migration HA forever; the seam already anticipates shared. (c) *Per-VM storage class:* over-engineered for a VDI control plane; pool/department granularity is enough and the golden-image backing chain wants a single store root per node.

**Consequences.** `NodePlacementService` and live-migration must branch on tier. Tier-S requires the mount to be present and writable on *every* node before a node reaches `status='online'` (plan §4.2). Tier-L caps migration throughput at NIC speed and forbids instantaneous failover. **Tier-S is the only tier with a shared-write double-run hazard** — this is what makes the agent self-fence on lease-loss load-bearing (§6, §8); Tier-L VMs have no peer that can co-open their overlay, so the fencing requirement is scoped to Tier-S.

```
Tier-S (shared)                          Tier-L (local + copy)
┌─ Ceph RBD / NFS export ─┐              node-A /var/lib/infinibay/data/disks
│  /infinibay/disks (all nodes mount)│   node-B /var/lib/infinibay/data/disks
│  golden/<sha256>.qcow2  (RO base)  │   golden pulled per-node on demand
│  vm/<vmId>/disk0.qcow2  (overlay)  │   overlay copied node→node on migrate
└────────────────────────────────────┘   cold = exportDisk→stream→importDisk
cold-migrate = nodeId flip               live = QEMU migrate + drive-mirror
live = QEMU migrate (RAM only)
```

### 2. ClusterStorage abstraction

A single backend service resolves storage decisions; the migration adapter (`VMStorageMigrationAdapter`, `VMMigrationService.ts:4-11`) becomes one consumer.

```typescript
type StorageTier = 'shared' | 'local';
type StorageDriver = 'nfs' | 'ceph-rbd' | 'dir';

interface ClusterStorageConfig {
  tier: StorageTier;
  driver: StorageDriver;
  // Tier-S: filesystem path that is identical & mounted on every node.
  sharedRoot?: string;          // e.g. '/infinibay/disks'
  // Tier-L: per-node root (always /var/lib/infinibay/data/disks today).
  localRoot: string;
  goldenStoreSubdir: string;    // 'golden'  -> content-addressed base images
  vmSubdir: string;             // 'vm'      -> per-VM overlay dirs
}

interface NodeStorageCapability {   // persisted per Node, refreshed via agent-push heartbeat
  nodeId: string;
  tiers: StorageTier[];             // ['shared','local'] | ['local']
  sharedRootMounted: boolean;       // Tier-S liveness probe result
  freeBytes: bigint;                // df of the active root
  reservedBytes: bigint;            // sum of provisioned-but-thin overlays
}

interface ClusterStorage {
  config(): ClusterStorageConfig;
  // Decide the migration strategy for a given VM + target. Drives MigrationJob.mode.
  planMigration(vmId: string, targetNodeId: string):
    Promise<'cold-shared' | 'cold-copy' | 'live-shared' | 'live-mirror'>;
  // Resolve the absolute disk path *as seen on a given node*.
  resolveDiskPath(vmId: string, nodeId: string, disk: string): string;
  capability(nodeId: string): Promise<NodeStorageCapability>;
}
```

`planMigration` is the single branch point: `tier==='shared' && sharedRootMounted` on both source+target → `cold-shared`/`live-shared`; else `cold-copy`/`live-mirror`. This replaces the bare env check at `VMMigrationService.ts:133-137` and is surfaced to the UI so the operator sees *why* a migration will be slow.

**Selection precedence:** explicit `ClusterStorageConfig.tier` > `INFINIBAY_SHARED_STORAGE` env (back-compat, `:136`) > default `local`. Tier-S downgrades to `cold-copy` for any node whose `capability.tiers` lacks `shared` — never silently uses a path that isn't mounted there.

> **Cross-ref (heartbeat direction).** `NodeStorageCapability` is refreshed on the **agent-push lease-renewal heartbeat**, not a master-pull. Storage relies on this because the same renewal path is what arms self-fencing for Tier-S double-write safety (§6). The liveness/fencing model is owned by **Control-Plane/Observability**; this section consumes the agent-push variant and would be incorrect under master-pull.

### 3. qcow2 lifecycle & backing chains

Infinibay already uses **base/overlay chains**: golden image = read-only base, each VM = thin linked clone via `qemu-img create -f qcow2 -F qcow2 -b <backing>` (storage.types `CreateImageOptions.backingFile:106-110`; schema `:515`). The invariant that survives multi-node:

> **A VM overlay is only runnable on a node where its entire backing chain resolves to identical bytes.**

```
golden/<sha256>.qcow2   (RO, immutable, content-addressed)
        ▲ backingFile
vm/<vmId>/disk0.qcow2    (RW overlay, this is what migrates)
        ▲ optional backing
vm/<vmId>/disk0.snap-<ts>.qcow2  (external snapshot overlay)
```

- **Tier-S:** chain lives once in `sharedRoot`; every node resolves the same backing path. Migration moves nothing.
- **Tier-L:** the *base* is distributed by content address (§4) so the backing path is byte-identical per node; only the **overlay** (small, user-delta) is copied on migration. This keeps `cold-copy` payloads to gigabytes, not the full virtual disk.

Before copy/mirror, the agent runs `qemu-img check` (`ImageCheckResult`, storage.types `:76-87`) on the source overlay; a non-zero `corruptions` aborts the `MigrationJob` in `preparing` rather than propagating corruption.

### 4. Golden-image distribution — content-addressed store + distribution scheduler

**Decision.** Make `GoldenImage` content-addressed and distribute base images by SHA-256, with **pull-on-demand** as the always-available floor and **pre-seed** as a *scheduled, rate-limited, peer-assisted* placement optimization that never saturates the master NIC and never blocks placement.

`GoldenImage` (schema `:616-657`) gains a digest and per-node presence is tracked, *not* by widening the row but via the existing `Disk` model (schema `:200-208`), whose `(path, nodeId, status)` shape is exactly an image-presence ledger.

```prisma
model GoldenImage {
  // + digest of the sealed qcow2; the content address. Filename becomes
  //   <goldenStoreSubdir>/<digest>.qcow2 on every node. Immutable (schema :625).
  contentHash String?  @unique     // 'sha256:...'
}
// Disk rows reused as a per-node image-presence ledger:
//   path='golden/<digest>.qcow2', nodeId=<node>, status='present'|'pulling'|'failed'
```

**Pull-on-demand (default, always the floor):** when placement lands a VM on a node lacking the base, the agent streams it from a valid source (any node holding `Disk{golden,present}`, or `sharedRoot`) over the authenticated transport (§7) into `golden/<digest>.qcow2.partial`, verifies SHA-256 == `contentHash`, atomically `rename(2)` to the final path, and writes a `Disk{status:'present'}` row. Concurrent pulls de-dup on the `.partial` lock. Placement is **never** blocked on pre-seed — a missing base just incurs a first-boot pull.

**Pre-seed via an image-distribution scheduler.** A `GoldenImage.status` flip to `published` (schema `:626`) does **not** fan a `pullImage(digest)` RPC out to all nodes at once — a 20-40 GB Windows golden × N nodes pulling from one source would saturate the management NIC and starve heartbeat/console/RPC traffic that shares that plane (networking §6). Instead the master runs a bounded, content-addressed distribution scheduler:

```typescript
interface ImageDistributionPolicy {
  maxConcurrentPulls: number;     // cluster-wide cap, e.g. 3 in-flight pulls total
  perStreamBytesPerSec: bigint;   // per-pull rate cap (token bucket at source agent)
  aggregateBytesPerSec: bigint;   // sum cap on the management plane
  seedFromPeers: boolean;         // true: any present node is a valid source (tree fan-out)
  scopeLabels: string[];          // only nodes whose labels match a pool referencing the image
}
```

```
master holds D (1 seeder)                 after wave 1 (3 seeders)
        master                                    master
       /  |  \   (≤maxConcurrent)              /     |     \
      n1  n2  n3                              n1     n2     n3
                                             / \    / \    / \
   wave 2 pulls fan OUT from n1..n3 ────────n4 n5  n6 n7  n8 n9
   each new 'present' node becomes a seeder; distribution is O(log N) waves,
   not O(N) concurrent egress from one NIC.
```

- **Concurrency + bandwidth bounded.** At most `maxConcurrentPulls` streams cluster-wide; each source agent enforces `perStreamBytesPerSec` via a token bucket, the master enforces `aggregateBytesPerSec` by admission-controlling how many pulls it schedules. Pulls are staggered, low-priority, and preemptible by control-plane traffic.
- **Peer/tree distribution.** Because images are content-addressed, *any* node with `Disk{path:'golden/<digest>', status:'present'}` is a cryptographically verifiable source. The scheduler treats every freshly-present node as a new seeder, so fan-out is O(log N) waves from O(log N) seeders rather than all-from-master. The master only sources the first wave.
- **Strictly scoped + opt-in.** Pre-seed targets only `online` nodes whose labels match a pool that references the image (`scopeLabels`). Nodes outside the scope get the image lazily via pull-on-demand.

**Why content-addressed:** golden images are explicitly immutable ("modifying it invalidates every clone", schema `:624-625`). A digest gives free cross-node dedup, a verifiable pull target, the peer-seeding property above, and makes the backing-path invariant (§3) checkable: a node may run a clone iff it holds a `Disk{path:'golden/<digest>'}` with `status='present'`.

### 5. Per-node disk capacity tracking

`Disk` (schema `:200-208`) already keys storage to `nodeId`. Capacity feeds `NodePlacementService` (the CPU/RAM scorer gains a disk axis) and migration pre-checks.

```typescript
interface NodeDiskCapacity {     // derived from agent-push heartbeat, not stored raw
  nodeId: string;
  totalBytes: bigint;            // df of localRoot (or sharedRoot quota)
  freeBytes: bigint;
  // Thin-provision aware: overlays grow. Worst-case if every overlay fills.
  provisionedBytes: bigint;      // Σ Machine.diskSizeGB on this node
  goldenBytes: bigint;           // Σ present golden images (shared once)
  overcommitRatio: number;       // provisioned / total — placement guardrail
}
```

Placement rejects a target where `machine.diskSizeGB` (thin worst-case) would push `overcommitRatio` past a cluster policy ceiling. Heartbeat carries `freeBytes`; staleness derives from `Node.lastHeartbeat` (plan §2). Golden bytes are counted once on Tier-S, per-node on Tier-L.

### 6. Snapshots & backups in a multi-node world

**Snapshots stay co-located with the running VM** (they are external qcow2 overlays in `vm/<vmId>/`, §3). On migration the snapshot chain travels with the overlay (Tier-L copy includes `*.snap-*.qcow2`; Tier-S needs no move). Live-migration with external snapshots requires the chain present at the destination *before* `prepareIncoming` — enforced by the same `cold-copy` mechanism ahead of the RAM transfer.

**Tier-S double-write fencing (storage-side requirement).** A Tier-S overlay is reachable for write from *every* node. If a node is partitioned-but-alive and the master reassigns its VMs, two QEMU processes could co-open one overlay → corruption. The defense is the agent's lease-loss self-fence:

- The self-fence **does not consult the DB**. There is exactly one agent per host, so every QEMU under the agent's `pidfileDir`/local pidfiles is *by construction* this node's; the agent can enumerate and `SIGKILL` them from local pidfiles/`/proc` with **no RPC read** — which is essential because during the partition there is no master/DB to query (the agent has no local DB).
- This kill path is distinct from orphan classification. The **reaper fails closed on DB error** (never kills an *unverified* PID) — that is the orphan-classification path, owned by Control-Plane. The **self-fence kills unconditionally on lease-loss** — that is the liveness path, and storage requires it **only for Tier-S VMs**, which are the only ones with a shared-write hazard. Tier-L VMs may be left running on a partitioned node without corruption risk (their overlay has no second writer); whether they are killed is a Control-Plane availability choice, not a storage-correctness one.
- A hardware/softdog watchdog backstops a wedged agent that cannot run its own self-fence.

> **Cross-ref.** The reaper/self-fence *mechanism and inequality* (`AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD`) are owned by **Control-Plane/Observability**. This section states only the storage-correctness contract it must satisfy: no two writers on one Tier-S overlay.

**Backups decouple location from execution.** `Backup.destinationDir`/`BackupSchedule.destinationDir` (schema `:1683,:1708`) already exist; redefine them as **cluster-addressable repositories**, not node-local paths:

```prisma
model Backup {
  // destinationDir reinterpreted: a backup repository URI, node-independent.
  //   Tier-S: lives in sharedRoot/backups -> restorable to ANY node.
  //   Tier-L: lives on the master backup store, pushed from the executing node.
  executedOnNodeId String?   // provenance: which agent ran qemu-img/the export
  // restore target chosen at restore time, NOT pinned to executedOnNodeId.
}
```

- **Where backups live:** a master-anchored (or shared) repository, never solely on the compute node — a backup pinned to a node that later dies is worthless for HA.
- **How execution routes:** the master's `NodeDispatcher` runs the export on the node currently hosting the VM (`Machine.nodeId`), streaming via the agent's `exportDisk` into the repository with a checksum over the §7 transport.
- **How restore targets a node:** restore is a placement decision. The master picks a target via `NodePlacementService`, ensures the golden backing chain is present there (§4 pull), then `importDisk` lands the backup overlay and assigns `nodeId`. A backup is therefore a node-agnostic artifact whose restore is "create a VM on the best node from this image."

### 7. Cross-node disk transport — channel auth, confidentiality & integrity

SHA-256 (below) gives end-to-end **integrity** but not **channel authentication** or **confidentiality**. VM overlays contain tenant secrets; raw NBD has no auth. Streaming them over the LAN with no peer authentication would be open to passive exfiltration and active injection during `importDisk`. The transport is defined explicitly.

**Decision (peer data channel).** Cross-node disk bytes flow over an **authenticated, confidential channel**, by one of two mechanisms keyed off the existing PKI's constraints (node certs are EKU `clientAuth`-only, onboarding §1/§7):

- **Default — proxy through the master (no direct agent↔agent socket).** Source agent `exportDisk` streams to the master over its existing master↔agent mTLS leg; the master relays the same bytes to the destination agent over *its* mTLS leg, into `importDisk`. Two `clientAuth` legs, zero new cert capability, every byte authenticated and encrypted by the PKI already in place. The master is a streaming relay, not a buffer (bounded backpressure window), and applies the same rate/aggregate caps as §4. This is the always-correct floor.
- **Opt-in — direct peer mTLS for high-volume copy.** To avoid the master as a throughput bottleneck on large `cold-copy`/`drive-mirror` payloads, node certs may be issued with **both `clientAuth` and `serverAuth`** (a deployment/PKI policy choice, owned by Onboarding). The destination agent then opens a listening TLS socket; both sides perform **mutual TLS with cert-pinning**, and the master hands each side a **short-lived, job-scoped token bound to `MigrationJob.id`** (the same fence used to gate the transfer). NBD runs **inside** that TLS tunnel, bound to the management/overlay plane only — never a routable interface, never raw on the wire.

```typescript
// Master issues this when it authorizes a transfer; presented by BOTH agents.
interface DiskTransferGrant {
  jobId: string;            // MigrationJob.id — the fence; one transfer, one grant
  vmId: string;
  digestOrOverlay: string;  // golden digest, or vm/<vmId>/disk0.qcow2
  srcNodeId: string;        // must equal mTLS cert identity of the source agent
  dstNodeId: string;        // must equal mTLS cert identity of the destination agent
  mode: 'proxy' | 'direct';
  notAfter: string;         // short TTL; expires with the job
  pinnedPeerCertFingerprint?: string; // direct mode: SHA-256 of expected peer cert
}
```

The agent rejects any transfer whose `srcNodeId`/`dstNodeId` does not match the mTLS cert identity of its peer (or, in proxy mode, of the master leg), so a transfer cannot be redirected to or sourced from an unauthorized node.

**Per-VM HMAC key travels JIT — the master secret never does.** Cross-ref **Security-RBAC/Deployment-Installer**, which own host→guest command auth, but it constrains migration here: a migrated VM's guest verifies host commands with a **per-VM** key `HMAC(INFINISERVICE_HMAC_MASTER_SECRET, vmId)` **derived on the master**. The fleet-wide `INFINISERVICE_HMAC_MASTER_SECRET` is **never distributed to any compute node**. On VM-create and on migration, the master pushes only the *derived per-VM key* over the authenticated RPC to the node(s) currently hosting the VM (and to the destination node at migration cutover, JIT). This preserves the blast-radius property (a compromised node yields only the per-VM keys of VMs it hosts, never the master secret, never forge-for-the-fleet) while still satisfying migration. **Migration does not require the master secret on nodes; shipping the per-VM derived key to the destination JIT solves it.**

### 8. Data integrity

- **Checksums end-to-end.** Every cross-node transfer (golden pull, `cold-copy`, backup export) carries a SHA-256 computed at source and re-verified at destination before the artifact is made visible. Mirrors the existing `ISO.checksum` discipline (schema `:219`) and the agent RPC's "streaming + checksum" contract (plan §3.2). This is *integrity*; *channel auth/confidentiality* is §7.
- **Atomic publish.** Write to `<name>.partial` → `fsync` → `qemu-img check` (storage.types `:76-87`) → verify digest → `rename(2)` (atomic on same filesystem) → DB row. A crash mid-transfer leaves only a `.partial` to be GC'd; no consumer ever opens a half-written backing file. The original is never deleted until the destination is confirmed (`cold-copy` rollback, plan §6.1).
- **ENOSPC handling.** Pre-flight: placement rejects targets failing the §5 thin worst-case check. In-flight: `exportDisk`/`importDisk` map a write `ENOSPC` to a structured `StorageError{code: COMMAND_FAILED}` (storage.types `:156-181`) that fails the `MigrationJob` in `copying` with the source intact and the `.partial` reaped — never a partially-imported overlay marked usable. Thin overlays can also hit ENOSPC at *runtime*: the agent watches `freeBytes` and emits a critical heartbeat alert + pauses the VM (QMP `stop`) before the host fills, rather than letting QEMU abort the guest.

### 9. Failure modes & recovery

| Failure | Detection | Recovery |
|---|---|---|
| Golden pull corrupted | digest mismatch post-stream | discard `.partial`, retry from another `present` seeder / master; never publish |
| Backing chain absent on target | placement check: no `Disk{golden,present}` row | trigger pull-on-demand before VM start; block start until present |
| `cold-copy` interrupted | `MigrationJob` stuck in `copying`, agent timeout | source untouched; reap `.partial`; `MigrationJob='rolled_back'`; VM stays on source |
| Peer channel auth failure (cert/identity/token mismatch) | mTLS handshake or `DiskTransferGrant` validation fails | abort transfer; no bytes accepted; `MigrationJob='failed'`; source intact |
| Tier-S mount lost on a node | heartbeat `sharedRootMounted=false` | node drops out of `online` for placement; in-flight live-migrations to it `migrate_cancel` |
| Tier-S partition (double-write risk) | agent lease-renewal failure | agent self-fences (SIGKILL local QEMU from pidfiles, no DB read); master reassigns only after declare-dead (§6) |
| Overlay corrupted | `qemu-img check` corruptions>0 | abort op in `preparing`; surface to UI; offer restore-from-backup |
| Node death with local-only VMs | heartbeat gap > threshold | Tier-L: VMs unrecoverable without a backup → drives the "backups must not be node-pinned" rule (§6); Tier-S: re-`nodeId` overlay onto a live node and restart (after source fenced) |
| Pre-seed starves control plane | aggregate management-plane bandwidth alert | scheduler honors `aggregateBytesPerSec`/`maxConcurrentPulls`; pulls preempted by control traffic; pull-on-demand remains the floor |
| Runtime ENOSPC (thin grow) | agent `freeBytes` watcher | QMP `stop` VM, critical alert, refuse new placements on node |

The hard rule across all paths, and the reason content-addressing + atomic publish + authenticated transport are non-negotiable: **the source artifact is authoritative until the destination is checksum-verified and atomically published over an authenticated channel; nothing in between is ever made visible to QEMU or recorded as usable in the DB, and no overlay is ever co-opened on Tier-S.**

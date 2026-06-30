## Security, RBAC & Multi-tenancy

This subsystem defines the trust model that makes the master↔agent control plane safe. It composes three **independent** cryptographic planes (do not collapse them — each defends a different boundary), extends the existing action/verb RBAC for node operations, and closes the tenant-isolation gaps that multi-node opens. It depends on, but does not design: the **Node Agent / RPC transport**, the **Onboarding/pairing flow**, the **Migration orchestrator**, and the **Observability/STONITH fencing** subsystem (all referenced by name).

**Revision note (adversarial review):** the v1 SAS-as-MITM-control claim was unsound and is withdrawn; the master HMAC secret is no longer distributed to nodes; agent→master calls are now cert-scoped; decommission now positively fences; the peer disk channel, console authz, overlay encryption, audit durability, and table retention are now specified. Each fix is called out inline.

### 1. Three trust planes (do not conflate)

| Plane | Secures | Mechanism | Existing anchor | Scope of compromise |
|-------|---------|-----------|-----------------|---------------------|
| **Control channel** master↔agent | RPC: create/start/migrate, console tickets, DB proxy | **mTLS**, per-node client cert signed by master CA, fingerprint-pinned | *new* — `Node.fingerprint/certPem` (plan §2) | one node |
| **Guest command channel** host→in-VM agent | infiniservice commands over virtio-serial | HMAC-SHA256, per-VM key `K_vm = HMAC(master, vmId)` **derived on master, shipped JIT** | `INFINISERVICE_HMAC_MASTER_SECRET` (master-only), `AgentMessageSigner.ts:9-19,56-60` | one VM |
| **User session** browser↔backend | GraphQL auth, JWT + refresh rotation | `TOKENKEY` (`jwtAuth.ts:62`), `RefreshToken` (`schema.prisma:53`) | one user |

**Critical composition rule (corrected):** keys are never shared **and the fleet-wide master HMAC secret never lands on a compute node.** `INFINISERVICE_HMAC_MASTER_SECRET` lives **only on the master** (alongside the CA key and `TOKENKEY`). The per-VM guest key `K_vm = HMAC(master, vmId)` is derived **on the master** and pushed over the authenticated RPC to **only the node(s) currently hosting that VM**, written to a `0600` tmpfs-backed file the node QEMU/infiniservice supervisor reads, and **re-derived-and-pushed to the destination at migration** (so the migrated guest's unchanged secret verifies without any node ever holding the master secret). This makes the blast-radius claim true: a compromised node yields the `K_vm` of **only the VMs it currently hosts**, never a forging key for the fleet.

> **Supersedes v1 §1/§4**, which placed `INFINISERVICE_HMAC_MASTER_SECRET` on every node "so a migrated VM's secret verifies." JIT push of the derived `K_vm` solves migration without that exposure; the secrets table in §4 is corrected accordingly. This aligns with the **Deployment-Installer §8** model (single source of truth: master-derived, JIT-shipped).

```
master CA (root key on master only) + INFINISERVICE_HMAC_MASTER_SECRET (master only)
 ├── master server cert        → agents pin its FULL fingerprint, set OOB (defeats rogue master)
 ├── per-node client certs      → master pins each in Node.fingerprint; CN=nodeId is the ONLY
 │                                authority for agent-originated calls (§5)              (defeats rogue node)
 └── K_vm = HMAC(master, vmId)  → derived on master, pushed JIT to current host only     (one-VM blast radius)
```

The agent authenticates **as a host**, not as a user. There is no user identity on the RPC channel: the *master* is the only RBAC point — but "sole RBAC point" only holds if the master **trusts nothing the agent asserts about identity** (§5).

### 2. RBAC extension — node verbs

Extend `RESOURCES` (`registry.ts:90-91`) — `node` is **global** (`scoped:false`); physical infra is not department-owned. Add the privileged lifecycle verbs:

```ts
// registry.ts — replace the node ResourceDef
{ key: 'node', label: 'Nodes', group: 'Infrastructure', scoped: false, nav: 'infrastructure',
  verbs: ['view', 'create', 'edit', 'approve', 'join', 'migrate', 'decommission', 'fence'] },
```

`node:manage` auto-expands to all of these (`registry.ts:139-141`), and `infrastructure:manage` already bundles `node:manage` (`registry.ts:144`) — so **ADMIN inherits every node verb automatically** via `ADMIN_GRANTS` (`presets.ts:24-25`), no preset edit required. Verb meanings:

- `node:view` — read inventory/health (already wired on `nodes/node/nodeInventorySummary`, `resolver.ts:56,79,104`).
- `node:approve` — approve/reject a `pending` node. **Most dangerous verb** — admits a new root executor.
- `node:join` — held by the **agent bootstrap identity**, not a human; gates the unauthenticated `POST /node/join` rate-limit/quota (§3).
- `node:migrate` — fleet-level placement-target choice. Distinct from `vm:migrate` (`registry.ts:47`). Migration requires **both**: `vm:migrate` on the instance (scope-checked, `machine/resolver.ts:324`) **and** `node:migrate`.
- `node:decommission` — revoke cert + reassign/evict VMs **and trigger positive fencing** (§4a).
- `node:fence` *(new)* — manually invoke STONITH on a node believed rogue/partitioned, independent of graceful decommission.

`vm:migrate` already exists as an OWN-scopable verb but USER preset does **not** grant it (`presets.ts:33-47`) — keep it that way. Wire the verbs (`@Can` runs the possession-only path for global resources, `decorator.ts:56-57`):

```ts
// node/resolver.ts
@Mutation(() => NodeType) @Can('node:approve', { id: (a) => a.id })
async approveNode(@Arg('id', () => ID) id, @Arg('confirmCaFingerprint') caFp: string, @Ctx() ctx) { … }

@Mutation(() => Boolean) @Can('node:decommission', { id: (a) => a.id })
async decommissionNode(@Arg('id', () => ID) id, @Arg('force', () => Boolean) force, @Ctx() ctx) { … }

@Mutation(() => Boolean) @Can('node:fence', { id: (a) => a.id })
async fenceNode(@Arg('id', () => ID) id, @Ctx() ctx) { … }
```

**Delegation guard.** `PermissionService.coversGrant` (`PermissionService.ts:114-123`) already blocks minting a role with `node:*` you lack; ensure role-editing mutations route through `assertCanGrant` (they already do).

### 3. Onboarding authorization state machine + anti-MITM (corrected)

`Node.status` (plan §2) is the authz gate:

```
            POST /node/join (agent, unauthenticated, rate-limited, carries CSR)
 (none) ───────────────────────────────────────────────────▶ pending
                                                                 │ node:approve reject
        pending ──[ node:approve + FULL CA fp OOB match ]──▶ approved ──────────▶ rejected
                                                                 │
                  agent pins master server FULL fp (OOB-seeded)  │
                                              approved ──────────┴──▶ online
                                                                 │ node:decommission / node:fence
                                                                 ▼
                                            (FENCE: storage+net+power) → decommissioned (cert revoked)
```

**Anti-MITM — root of trust is the FULL master-CA fingerprint compared out-of-band, not a 6-digit SAS.**

The v1 SAS proof (`sas6 = uint32_be(SHA256(tag‖nodeKeyFp‖masterCaFp‖nonce)) mod 1e6`) is **withdrawn as a MITM control.** It is ~20 bits, has no commitment round, and a terminating MITM learns the node's CSR-pubkey fp, the real master CA fp, and the nonce *before* it must choose the CA it substitutes toward the node. It can relay the node's real CSR to the master (matching the master's display), compute the master's target value, then grind ~10⁶ candidate CAs (vary serial/validity/key) until the node-side digest collides — **both screens show the same code while the node pins the attacker CA.** SAS over independently-grindable public keys with no commitment is broken at 20 bits.

The corrected protocol uses **two** controls, both mandatory:

1. **Out-of-band full-fingerprint admission (the actual root of trust).** During `setup.sh` the master prints its **full** SHA-256 CA fingerprint to its own console and into the provisioning channel (`/var/lib/infinibay/ca/ca.fpr`). The operator transcribes/scan-QRs this **full** fingerprint to the node, and the agent **refuses to proceed unless the CA it is about to pin matches the OOB value digit-for-digit.** This value is read from the master's own console, *not* learned over the spoofable mDNS/HTTP discovery path — so a MITM cannot substitute its CA without also forging a 256-bit fingerprint match (infeasible). `approveNode(confirmCaFingerprint)` requires the operator to paste back the same full fingerprint, binding both ends to the same root.

2. **Commitment-bound pairing (closes the adaptive-key window).** Before any reveal, master sends `commit_M = H(caCertDer ‖ nonce)` and node sends `commit_N = H(csrPubkeyDer ‖ nonce)`; both commitments are displayed/exchanged **first**, then each side reveals its value and verifies the peer's commitment opens. Because the CA is committed before the node's pubkey is revealed (and vice-versa), neither side can adapt its key after seeing the other's — the grind attack has nothing left to grind against. The 6-digit code derived **after** opening is now only a **UX convenience** ("do these two short codes match? then you transcribed the fingerprint correctly") and is **no longer claimed to defeat MITM**; the full-fingerprint OOB comparison (control 1) is.

`POST /node/join` remains the **only** unauthenticated endpoint: it can only insert `status='pending'` with the submitted CSR + hardware info, never mutate an existing node; per-source-IP rate-limited; no cert signed until `approved`. `Node.fingerprint` is `@unique` (plan §2) so a re-join cannot shadow an existing pin.

> **Cross-ref:** the discovery/transport of `commit_*` and the nonce is owned by the **Onboarding/pairing** subsystem; this section mandates the commitment ordering and the full-fingerprint OOB gate it must implement.

### 4. Master-side enforcement, fencing, and secrets at rest

#### 4a. Decommission/fence = positive eviction, not just CRL (corrected)

CRL + short leaf TTL only blocks **new** handshakes; a compromised or partitioned agent keeps running its QEMU and, on shared storage, keeps writing the qcow2 the master may re-home — concurrent-writer corruption. `decommissionNode(force)` and `fenceNode` therefore invoke the **same STONITH machinery the Observability-Ops §3 subsystem defines** (this section consumes it, does not redesign it), in order, before declaring the node removed:

```
fence(nodeId):
  1. STORAGE   → break the node's shared-storage hold:
                 Ceph: `rbd lock blocklist` + add node client to OSD blocklist;
                 NFS: NLM lock-break / `exportfs` deny for the node's client IP.
  2. NETWORK   → quarantine: drop the node's VTEP from every department FDB,
                 revoke its overlay key (§5b), pull its underlay ingress allow-entry.
  3. POWER     → BMC/IPMI chassis-off or PDU outlet-off where available (hard STONITH).
  4. CERT      → revoke leaf, publish CRL, set Node.status='decommissioned'.
  Order matters: storage+network eviction must complete BEFORE the master re-homes
  any VM that node held (no two writers to one qcow2). Power-fence is the backstop
  when storage/net fencing cannot be confirmed.
```

Graceful path (`force=false`, node still healthy) drains VMs via migration first, then steps 1–4. `force=true`/`fenceNode` skips drain. The CRL is the *last*, weakest step — never the only one.

#### 4b. Secrets at rest (corrected)

| Secret | Location | At-rest protection |
|--------|----------|--------------------|
| CA private key | **master only**, `/var/lib/infinibay/ca/ca.key` | root `0600`, never in DB, never logged; gen in master `setup.sh` |
| Per-node client key | each node, `/var/lib/infinibay/agent/agent.key` | root `0600`; CSR-only flow — master never sees it |
| `INFINISERVICE_HMAC_MASTER_SECRET` | **master only**, root systemd `EnvironmentFile` | **corrected — removed from nodes**; used only to derive `K_vm` |
| Per-VM guest key `K_vm` | node currently hosting the VM, **tmpfs `0600`**, JIT-pushed | ephemeral; wiped on VM stop/migrate-out; never persisted to disk or DB |
| `TOKENKEY`, DB creds | master only | env; not propagated to agents |
| IdP bind passwords | DB (`IdentityProvider.bindPasswordSecret`) | encrypted with `IDENTITY_SECRET_KEY`/`TOKENKEY` (`IdentityProviderService.ts:69-74`) |

### 5. Master-side node-scoping, tenant isolation, and the agent↔agent data channel

#### 5a. The master scopes EVERY agent-originated operation to the cert CN (corrected — was the central gap)

ADR-CP1's `RpcDatabaseAdapter` must **not** be a transparent Prisma passthrough. On every agent-originated call the master derives `nodeId := verifiedClientCert.CN` from the **completed mTLS handshake** and treats any agent-supplied `nodeId`/`vmId` as **untrusted input**. The adapter is a **node-scoped facade**:

```ts
// master: RpcDatabaseAdapter is constructed per-connection, bound to the verified cert
class NodeScopedDbFacade {
  constructor(private readonly certNodeId: string) {}   // CN from mTLS, NOT from payload

  async findMachineByInternalName(name: string) {
    const m = await prisma.machine.findUnique({ where: { internalName: name } });
    if (m && m.nodeId !== this.certNodeId) throw new ForbiddenError('cross-node read');
    return m;                                            // null leak-safe; never returns peers' rows
  }
  async updateMachineStatus(vmId: string, status: VmStatus) {
    const owned = await prisma.machine.count({ where: { id: vmId, nodeId: this.certNodeId } });
    if (!owned) throw new ForbiddenError('cross-node write');
    return prisma.machine.update({ where: { id: vmId }, data: { status } });
  }
  // every method filters/asserts on nodeId === certNodeId; no raw Prisma escape hatch is exposed.
}
```

**Heartbeat is likewise cert-scoped.** Each `vms[]` entry and its `qmpStatus` are folded into `Machine.status` **only for machines whose `nodeId === certNodeId`**; entries claiming any other node's VM are rejected and alerted. A compromised agent therefore cannot read the fleet's `Machine` table, flip a peer's VM to `off`, or keep a dead peer's `lastHeartbeat` fresh to block fencing — the cert CN is the sole authority, payload identity is ignored.

This is **defense-in-depth with §5b's agent-side `Machine.nodeId===self` fence**: the agent fences what the master directs; the master fences what the agent reports. Neither trusts the other's identity claims.

#### 5b. G0 ownership fence + placement

1. **G0 (data-safety blocker).** `Infinization({ nodeId })` and reconcile scope `findRunningVMs`/orphan-reaper to the **local nodeId** (plan §3.3); the agent asserts `Machine.nodeId === self.nodeId` before acting — the one place the agent enforces authorization.
2. **Placement.** `NodePlacementService` respects `Node.labels` for tenant pinning (e.g. `{zone:'dept-finance'}`); `scopeCovers` (`scope.ts:112-129`) is unchanged — a MANAGER reaches their VM regardless of host; cross-node moves still require `node:migrate`.

#### 5c. Cross-node disk data channel (corrected — was unauthenticated)

Migration's "open one TCP/NBD channel" left node↔node disk bytes (containing tenant secrets) with **no peer auth or confidentiality** — node certs are `clientAuth`-only, so an agent cannot be a TLS server to a peer under the v1 PKI, leaving raw NBD in cleartext. **Decision: option (b) — dual-EKU job-scoped mTLS tunnel:**

- Node leaf certs are issued with **both `clientAuth` and `serverAuth`** EKUs (onboarding §1/§7 updated accordingly).
- For a migration, the master mints a **short-lived, job-scoped bearer token bound to `MigrationJob.id`** and hands one to each side; the source listens and the target dials a **mutual-TLS** connection, each **pinning the peer's `Node.fingerprint`** from the DB. NBD runs **inside** that TLS tunnel, bound to the management/overlay plane, **never a routable interface**.
- The token is single-use, expires with the job fence, and is logged. Storage §7's SHA-256 still provides end-to-end integrity; the tunnel adds channel auth + confidentiality.

*Alternative (a) — proxy all bytes through the master over the two existing master↔agent legs* — keeps node certs `clientAuth`-only and needs no PKI change, but doubles WAN bytes and makes the master a throughput bottleneck; chosen as fallback for collapsed single-NIC deployments, selectable per `MigrationJob`.

#### 5d. Cross-node overlay isolation (corrected — VXLAN is cleartext)

"department = VNI = isolation boundary" does **not** hold on a shared underlay: VXLAN is unauthenticated/unencrypted; any underlay host (incl. one compromised node) can spoof a VTEP source IP, inject into any VNI, or sniff decapsulated tenant traffic. `nolearning`+static FDB controls the control plane only. **Required:** run VXLAN **inside WireGuard (or IPsec) between VTEPs**, keys distributed by the master and **rotated with node lifecycle** (revoked at fence, §4a step 2); **or**, where an encrypted overlay is infeasible, mandate a dedicated access-controlled underlay VLAN with **strict ingress filtering accepting UDP/4789 only from known peer VTEP IPs** and dropping all else. **Residual risk (state explicitly):** single-NIC collapsed-plane deployments where management/overlay/underlay share a segment are weaker — document and recommend the encrypted-overlay option there. The overlay/key-rotation mechanism is owned by the **Networking-overlay** subsystem; this section mandates its security properties.

### 6. Liveness model + audit durability

#### 6a. Heartbeat is agent-push lease-renewal (resolves the two-direction conflict)

The control-plane "master-pull" variant (v1/ADR-CP4) is **withdrawn** because it removes the only mechanism that prevents shared-storage double-writes after a partition. **Decision: agent-push lease renewal.** Each agent periodically `renewLease(nodeId-from-cert, vms[])` over its mTLS leg; the master records `lastHeartbeat`. The corruption-safety inequality is restored:

```
AGENT_SELFFENCE_AT  <  MASTER_DECLARE_DEAD
   │                        │
   │                        └─ master waits this long, then STONITH-fences (§4a) and re-homes VMs
   └─ a partitioned-but-alive agent that cannot RENEW its lease self-fences FIRST:
      stops local QEMU, releases shared-storage locks. Backed by a hardware/softdog
      watchdog so a WEDGED agent (can't run code) still resets and self-fences.
```

Every heartbeat's `nodeId`/`vms[]` is bound to the cert CN per §5a (no spoofed peer liveness). Control-plane §7/ADR-CP4 are rewritten to this model. *Cross-ref: the lease timer values and the watchdog wiring are owned by Observability-Ops §1/ADR-2; this section requires the inequality and the cert binding.*

#### 6b. Console gateway authorization (corrected — was IDOR/hijack-prone)

`wss://master/console/<sessionToken>` put the only authorization secret in the URL path (leaks via logs/history/Referer) with no user binding and no per-vmId permission check. **Corrected flow:**

1. `getConsoleSession(vmId)` **enforces the department-scope check on that vmId** via `scopeCovers`/`vm:view` (`scope.ts:112-129`) — an authenticated user can only get a session for a VM their scope covers (closes the cross-tenant IDOR). It mints a **single-use, short-TTL `sessionToken` bound server-side to `{userId, vmId, ticket}`**.
2. The WS upgrade carries the user's authenticated **JWT** (cookie/`Authorization`) **and** the `sessionToken` **out of the URL** (WS subprotocol or header); the gateway re-verifies `jwt.userId === session.userId` and `vm:view` still holds before bridging to the node's short-lived QMP ticket.
3. Session is **revoked on stop/migrate** (already planned) and on logout. The QMP ticket's single-use property protects only the node↔gateway hop; browser↔gateway authz is now the JWT + bound token. **Never** place the sole authz secret in the URL.

#### 6c. Audit durability + tamper-evidence (corrected — was failure-swallowing)

`PolicyAuditService` (`PolicyAuditService.ts:21-36`) is append-only **and failure-swallowing** — unacceptable for trust-root transitions, where an attacker inducing audit-write failure gets **unlogged cluster admission**. For `node.approved`, `node.rejected`, `node.decommissioned`/`fenced`, and `node.cert_revoked`, the audit write is made **part of the same DB transaction as the state change** — if the audit row cannot be written, the privileged operation **fails** (no silent success), and audit-write failures raise an ops alert. Rows are **hash-chained** (`prevHash = H(prev row canonical)`) for tamper-evidence independent of DB row mutability, so a master-DB compromise that rewrites the ledger breaks the chain detectably:

```ts
// trust-root transitions only — transactional, chained
await prisma.$transaction(async (tx) => {
  const node = await tx.node.update({ where: { id }, data: { status: 'approved', fingerprint, certPem } });
  const prev = await tx.auditEvent.findFirst({ orderBy: { seq: 'desc' } });
  await tx.auditEvent.create({ data: {
    actorId, action: 'node.approved', targetType: 'node', targetId: id,
    summary: `${actorEmail} approved node ${node.name}`,
    metadata: { fingerprint, caFingerprintConfirmed: true },
    prevHash: prev?.rowHash ?? GENESIS,
    rowHash: hashRow({ actorId, action: 'node.approved', targetId: id, prevHash: prev?.rowHash }),
  }});
});
```

Non-trust-root events (`node.join_requested`, `machine.migrated`) may keep the fire-and-forget `PolicyAuditService` path; heartbeat flaps are not audited (noise).

#### 6d. Retention for append-only tables (scale)

Unbounded growth degrades the single-writer Postgres. **Required:**

- **CommandOutbox** — time-partition (monthly) and drop old partitions, or run a periodic job moving `acked`/`dead` rows to an archive table; **the dispatcher poll uses a partial index** `@@index([nodeId, status, seq]) WHERE status IN ('pending','leased')` so it never scans acked history; tune autovacuum aggressively for this high-churn table.
- **AuditEvent / PolicyAuditLog** — month-partitioned; trust-root chained rows retained per compliance window, rest aged out.
- **NodeMetrics** — month-partitioned, rolled up to hourly aggregates then dropped; raw retention bounded.

*Cross-ref: exact partition cadence/retention windows are co-owned with the Storage/DB-ops subsystem.*

### 7. Threat model (updated)

| Asset | Threat | Mitigation |
|-------|--------|------------|
| Join handshake | **MITM key-substitution + grind** | Full CA fingerprint compared **out-of-band** (read from master console) is the root of trust; commitment-bound pairing closes the adaptive-key window; 6-digit code demoted to UX only (§3). |
| Cluster membership | **Rogue node** self-joins | `POST /node/join` → `pending` only; no cert until `node:approve`+full-fp match; rate-limited; `fingerprint @unique`. |
| Fleet DB / peer VMs | **Compromised agent reads/writes other nodes' state** | Master derives `nodeId` from cert CN and scopes every proxied DB op + heartbeat `vms[]` to it (§5a); agent-supplied ids untrusted. |
| Shared storage | **Rogue/partitioned node double-writes qcow2** | Agent self-fences on lease-renewal failure (watchdog-backed); master STONITH-fences storage+net+power before re-homing (§4a, §6a). |
| Cross-node disk stream | **Passive exfil / active injection** of VM disks | Dual-EKU mutual-TLS tunnel, peer-fp-pinned, job-scoped token; NBD inside the tunnel on mgmt/overlay plane only (§5c). |
| Cross-node tenant L2 | **VTEP spoof / overlay sniff** | VXLAN inside WireGuard/IPsec with lifecycle-rotated keys, or filtered dedicated underlay; residual risk noted for single-NIC (§5d). |
| Guest command channel | **Forged host→guest commands; fleet-wide forge key** | Per-VM `K_vm` derived on master, JIT-pushed to host only, tmpfs `0600`; master secret never on a node — leaked node forges only its hosted VMs (§1,§4b). |
| VM console | **Hijack / cross-tenant IDOR** | `vm:view` department check at `getConsoleSession`; single-use token bound to `{userId,vmId,ticket}` out-of-URL + JWT on WS upgrade; revoke on stop/migrate (§6b). |
| Trust ledger | **Unlogged admission / ledger tamper** | Transactional audit for trust-root transitions (fail-closed) + hash-chained rows (§6c). |
| Lateral movement | Stolen `TOKENKEY`/DB creds → whole fleet | master-only, never propagated; agent compromise yields no user JWTs; CA key never in DB. |
| RBAC | **Priv-esc via custom roles** | `coversGrant`/`assertCanGrant` (`PermissionService.ts:114-131`); DENY wins (`:65`); unknown perms fail-closed (`registry.ts:174`). |
| Hypervisor host | **QEMU runs as root** | Residual risk; roadmap: dedicated `infinibay-qemu` uid + cgroup slice + seccomp/`-runas`; node admission is the compensating control. |

### 8. ADRs

**ADR-S1 — mTLS for the control channel, not HMAC.** *Decision:* per-node client certs under a master-owned CA, fingerprint-pinned both ways. *Rationale:* per-node identity, revocability, encryption in one primitive; matches LXD's cert-trust model. *Alternatives rejected:* shared `INFINISERVICE_HMAC_MASTER_SECRET` for RPC (no per-node revoke); SSH trust (conflates host login with control authority). *Consequences:* CA lifecycle (gen/sign/revoke) + handshake CRL check; node leaf certs carry **both** clientAuth+serverAuth to enable the §5c peer tunnel.

**ADR-S2 — `node` stays a global RBAC resource; privileged verbs are leaf verbs.** *Decision:* add `approve/join/migrate/decommission/fence` to `node` (`registry.ts:90`); no per-node ownership. *Rationale:* hardware has no tenant owner; leaf verbs give ADMIN everything via `node:manage` and delegation via `coversGrant` for free. *Alternatives rejected:* per-node scoping; separate `cluster` resource. *Consequences:* any `node:approve` holder admits any node — acceptable since approval is the audited (now transactional/chained) trust root.

**ADR-S3 — agent authenticates as a host; the master is the sole RBAC point — but trusts only the cert CN.** *Decision:* no user identity on RPC; **the master derives `nodeId` from the verified client cert and scopes all agent-originated DB ops + heartbeats to it** (§5a); agents enforce only the local `nodeId` self-fence (§5b). *Rationale:* concentrates user-context authorization on the master while denying a compromised agent any cross-node reach; "sole RBAC point" is only sound if payload identity is untrusted. *Alternatives rejected:* forwarding user JWTs to agents (spreads `TOKENKEY` to every node); transparent Prisma passthrough (the original fleet-wide lateral-movement hole). *Consequences:* the `RpcDatabaseAdapter` must be a per-connection node-scoped facade; a leaked node compromises its own VMs only.

**ADR-S4 — master HMAC secret never leaves the master; per-VM keys are JIT-derived.** *Decision:* `K_vm = HMAC(master, vmId)` derived on master, pushed over RPC to the current host (and destination at migration), held in tmpfs only. *Rationale:* makes the one-VM blast-radius claim true and unifies with Deployment-Installer §8. *Alternatives rejected:* master secret on every node (one compromise forges the fleet). *Consequences:* migration orchestration must request and ship `K_vm` to the destination before guest cutover.

**ADR-S5 — full-fingerprint OOB comparison is the MITM root of trust; SAS is UX only.** *Decision:* mandatory digit-for-digit comparison of the master's full CA fingerprint read from the master's own console, plus commitment-bound pairing; the 6-digit code is demoted to a transcription-sanity check. *Rationale:* a 20-bit SAS over grindable, no-commitment public keys is defeatable by a terminating MITM. *Alternatives rejected:* shipping the grindable SAS as the MITM control (unsound); SAS-only with a commitment but no OOB channel (still learned over the spoofable discovery path). *Consequences:* onboarding UX must surface and verify a full fingerprint and implement the commit-before-reveal ordering.

**ADR-S6 — decommission/fence is positive STONITH, not CRL alone.** *Decision:* storage eviction → network quarantine → power fence → cert revoke, reusing Observability-Ops STONITH; storage+net eviction precedes any VM re-home. *Rationale:* CRL blocks only new handshakes; a rogue node keeps writing shared storage. *Alternatives rejected:* CRL + short TTL only (corruption window). *Consequences:* decommission depends on the fencing subsystem and on shared-storage blocklist/lock-break support per storage tier.

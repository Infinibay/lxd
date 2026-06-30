## Node Onboarding, Discovery & PKI

Scope: how a bare compute host goes from "freshly imaged" to a `status='online'` row in `Node` with a mutually-authenticated mTLS channel, in minutes, with **zero shared secrets typed by a human** and a cryptographic guarantee against impostor-node / impostor-master / MITM. This replaces the `setupNode` stub (`repos/backend/app/graphql/resolvers/setup/resolver.ts:14-46`) and turns `LocalNodeRegistrationService.detectLocalHardware()` (`repos/backend/app/services/node/LocalNodeRegistrationService.ts:65-96`) into the *node-side* hardware payload of a `join` request rather than a direct DB write.

It does **not** design the RPC dispatch (`NodeDispatcher`/`RemoteNodeClient`), heartbeat/staleness (→ Control-Plane / Observability-Ops, see §5/§7 cross-refs), the `nodeId`-scoping of infinization's reaper (G0), or per-VM HMAC key distribution (→ Deployment-Installer §8) — those are referenced as dependencies.

### 1. Trust model & PKI topology

Single offline-rooted CA, owned by the master, created once in `setup.sh`.

```
infinibay-root-CA (self-signed, P-384, 10y, key never leaves the CA host)
 ├── master-server-cert   (SAN: LB VIP + master LAN IP + hostname; EKU serverAuth)  ← agents trust via OOB-pinned CA
 └── node-client-cert × N (SAN: URI infinibay://node/<nodeId>; EKU clientAuth, 90d)  ← master pins SPKI
```

Two independent pins, persisted on both ends:
- **Master pins the node**: `Node.fingerprint` = SHA-256 of the node's leaf SPKI (planned schema, plan §2).
- **Node pins the master CA**: `masterCaFP`, established **out-of-band** (§4) — the node trusts the *CA*, not a leaf, so the master may rotate its server cert (or run multiple replicas, §7) without re-pairing.

**ADR-PKI-1 — Private CA + mTLS, not HMAC tokens or public ACME.**
*Decision*: master-owned X.509 CA, mutual TLS, fingerprint pinning. *Rationale*: a long-lived daemon channel wants channel-level identity, not per-message HMAC; it matches LXD's certificate-trust model. The `INFINISERVICE_HMAC_MASTER_SECRET` pattern (`setup.sh:404-409`) is the right primitive for short **host→guest** commands but is a *different layer* and **must never be distributed to compute nodes** — the fleet master secret stays on the master; per-VM keys `HMAC(master, vmId)` are derived on the master and shipped JIT over the authenticated RPC to the node(s) currently hosting the VM (and to the destination at migration). Owner: **Deployment-Installer §8**; this corrects the contradictory Security-RBAC §1/§4 rows that placed the master secret on every node (one node compromise would forge for the whole fleet — see Security-RBAC ADR-S3 blast-radius). *Alternatives rejected*: (a) public ACME — nodes are RFC1918, no DNS; (b) shared bearer token — one leak compromises the fleet, no per-node revocation; (c) SSH CA — no native streaming-RPC/mTLS story. *Consequences*: master must run CRL/renewal; CA key is a crown-jewel kept `0400 root` on the designated CA host (§7).

### 2. Discovery (mDNS / Avahi)

Master advertises on the LAN; the node browses. TXT carries everything needed to *start* (not complete) a join.

```
Service: _infinibay-master._tcp.local   port=<agentPort, default 9443>
TXT: v=1  api=/node/join  cafp=sha384:9f2c…e1  master=<masterNodeId>  name=infinibay-master
```

```
$ ./run.sh join
Browsing _infinibay-master._tcp … found:
  infinibay-master  192.168.1.50:9443  ca=9f2c…e1   (UNVERIFIED hint)
```

`cafp` in TXT is a **convenience hint only**. mDNS is spoofable, so it is **never** the root of trust — the binding root of trust is the out-of-band full CA fingerprint of §4. Manual fallback `--master 192.168.1.50[:9443]` skips browsing. Master advertises from master-side provisioning (`avahi-publish-service` or a small helper in the master agent).

### 3. Join message schemas

```typescript
// node → master : POST /node/join   (plain TLS to master server cert; NOT yet mutual)
interface JoinRequest {
  v: 1
  csr: string            // PEM PKCS#10; CN/SAN requested = infinibay://node/<proposedName>
  nodeKeyFp: string      // sha256 hex of node leaf SPKI (DER) — MUST equal CSR pubkey
  agentVersion: string
  hardware: LocalNodeHardware     // reuse detectLocalHardware() verbatim
  proposedName: string            // INFINIBAY_NODE_NAME || hostname
  underlayIp: string              // candidate VXLAN VTEP / data-NIC IP; single-NIC → = mgmtIp
}

// master → node : 202 Accepted
interface JoinPending {
  nodeId: string         // newly created Node(status='pending')
  nonce: string          // 16 random bytes, base64url
  masterCaPem: string    // full CA cert; node derives masterCaFp ITSELF (never trusts TXT)
  pollToken: string      // opaque, single-use, rate-limited
  sasExpiresAt: string   // ISO; pending row auto-expires (default 10 min)
}

// node → master : GET /node/join/:nodeId/status  (Bearer pollToken)
type JoinStatus =
  | { state: 'pending' } | { state: 'rejected' }
  | { state: 'approved'; signedCertPem: string; caChainPem: string; masterServerFp: string }
```

`underlayIp` closes the NodeUnderlay-ownership gap: the master persists it into `NodeUnderlay.vtepIp` at approve time (model owned by **Data-Model**; consumed by **Networking** before any cross-node department overlay works). Single-NIC nodes default `vtepIp = mgmtIp`, as Networking specifies.

### 4. Anti-MITM: out-of-band CA fingerprint is the root of trust

The earlier 6-digit "SAS" derived over public, independently-grindable inputs (node key FP, CA FP, relayed nonce) is **broken at ~20 bits**: a terminating MITM learns every input *before* it must pick the CA it substitutes toward the node, then grinds ~10⁶ candidate CA certs (vary serial/validity — microseconds each) until its forged CA hits the same 6-digit value the real master shows. Both screens then match while the node pins the attacker CA. **The short code is therefore demoted to UX convenience and is NOT a security control.**

The actual MITM control is an **out-of-band comparison of the FULL master CA fingerprint**, made the mandatory pinning gate:

```
masterCaFp = SHA-384( DER(master CA certificate) )    # 96 hex chars / 48 bytes
```

- The master **prints its full `masterCaFp`** at the end of `setup.sh` and persistently surfaces it: `infinibay master ca-fp`, the master-host console, and a fixed banner in Infrastructure ▸ Settings. This value is read from the master's *own* provisioning channel — not over the spoofable mDNS/HTTP path.
- The node operator supplies it to the join: `./run.sh join --master 192.168.1.50 --ca-fp sha384:9f2c…`. The node derives `masterCaFp` from the received `masterCaPem` and **refuses to pin / aborts on any byte mismatch**, fully non-interactive. Without `--ca-fp` the node prints the derived fingerprint and **blocks** until the operator confirms it digit-for-digit against the OOB value; it never silently TOFUs the mDNS hint.

Because the attacker's substituted CA has a different 384-bit fingerprint, the grind is useless: there is no 6-digit shortcut to collide a full hash. This is exactly LXD's "verify the server certificate fingerprint" model.

Two confirmations, two attacks closed:

| Step | Who | Verifies | Defeats |
|---|---|---|---|
| `--ca-fp` / node confirm | node operator | derived `masterCaFp` == OOB value from master console | impostor-master, mDNS/DNS spoof, **MITM** (forged CA can't match full FP) |
| Approve on master | admin (UI) | the host that POSTed is a host they intend to admit | impostor-node (rogue host) |

The 6-digit code is still shown on both screens as a fast human "are we looking at the same pairing" cross-check and to make `approveNode(id, expectedCode)` self-checking, but the design no longer relies on it for MITM resistance.

**ADR-PKI-2 — Full CA fingerprint over an out-of-band channel is the MITM control; the short code is UX only.**
*Decision*: pin the master CA by comparing/entering its full SHA-384 fingerprint obtained from the master's own console/provisioning channel; abort on mismatch. *Rationale*: any SAS short enough for a human (≤~32 bits) over public, attacker-known inputs with no per-session secret is grindable — a commitment round does not help because the long-lived CA gives the attacker a fixed offline target. Binding the full fingerprint OOB removes the shortcut entirely. *Alternatives rejected*: (a) ship the 20-bit SAS as the control — broken, demonstrated grind; (b) commitment protocol (master commits `H(CA‖nonce)`, node `H(nodeKey‖nonce)` before reveal) — still bottoms out at the displayed code's entropy and adds rounds without closing the offline-grind on the static CA; retained only as optional hardening for the node-key direction. *Consequences*: the operator must obtain `--ca-fp` once per master (printed by `setup.sh`); trivially automatable via the provisioning image/secrets channel.

### 5. Sequence

```
NODE (run.sh join --ca-fp X)      MASTER backend                 ADMIN (UI)
  | gen ECDSA keypair + CSR              |                            |
  | mDNS browse / --master               |                            |
  |  POST /node/join {csr,hw,underlayIp} |                            |
  |------------------------------------->| create Node(pending)       |
  |<-- 202 {nodeId,nonce,masterCaPem} ---|                            |
  | derive masterCaFp from PEM           |                            |
  | ABORT unless == X  (root of trust)   |                            |
  | poll status ...                      |  show pending + code -----> | admit host,
  |                                      |<-- approveNode(id,code) ----| approve
  |                                      | CA(leader)-signs CSR → leaf |
  |                                      | persist certPem,fingerprint,|
  |                                      | NodeUnderlay.vtepIp=underlay|
  |<-- {signedCertPem, masterServerFp} --|  status='approved'         |
  | install cert+key, CA already pinned  |                            |
  | open mTLS, push first heartbeat ---->| status='online'            |
```

`status`: `pending → approved → online`; side exits `rejected`, `offline`, `decommissioned`. The `approved → online` transition is owned by the heartbeat subsystem (**Observability-Ops §1 / ADR-2**), which is the **agent-push lease-renewal** model: the agent renews its lease on a fixed interval and **self-fences** (tears down local QEMU) when it cannot renew before `AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD`, backstopped by a hardware/softdog watchdog. Onboarding adopts that direction (resolving the Control-Plane §7/ADR-CP4 "master-pull" contradiction in favor of agent-push) and contributes the identity binding: **every heartbeat is authenticated by the node's mTLS client cert, and its `nodeId`/`vms[]` MUST equal the cert's `infinibay://node/<nodeId>` SAN** — a node can only assert liveness for its own identity. Onboarding's own terminal success is `approved` + cert delivered.

### 6. GraphQL / installer surface

```graphql
type PendingNode { id: ID!, name: String!, address: String!, sasCode: String!,
                   nodeKeyFp: String!, agentVersion: String!, hardware: JSON!, underlayIp: String!, createdAt: DateTime! }
extend type Query    { pendingNodes: [PendingNode!]! }              # @Authorized('NODE_ADMIN')
extend type Mutation {
  approveNode(id: ID!, expectedCode: String!): Node!               # @Authorized('NODE_ADMIN')
  rejectNode(id: ID!): Node!
  decommissionNode(id: ID!): Node!                                  # triggers fencing (§7)
  rotateNodeCert(id: ID!): Node!
}
```

`POST /node/join` is **unauthenticated** (no session) — protected by OOB CA pinning + admin approval + rate limiting (plan §4.3). New `NODE_ADMIN` permission extends the existing `@Authorized` system. Installer: `setup.sh` master path adds CA bootstrap (§7), prints `masterCaFp`, and the mDNS advert; `./run.sh join [--master IP] [--ca-fp FP]` installs qemu/kvm + infinization + agent and runs the node side of §4–5, calling `detectLocalHardware()` for `JoinRequest.hardware`. Wire `join` into the `run.sh` smart-default dispatcher (`run.sh:492-532`).

### 7. CA bootstrap, signing under HA, rotation, revocation

**Bootstrap (master `setup.sh`, secret-gen block `setup.sh:398-411`):** idempotent like `ensure_secret` (`setup.sh:420-435`).
```bash
PKI=/var/lib/infinibay/pki
install -d -m700 "$PKI/ca" "$PKI/server"
openssl ecparam -name secp384r1 -genkey -noout -out "$PKI/ca/ca.key"; chmod 400 "$PKI/ca/ca.key"
openssl req -x509 -new -key "$PKI/ca/ca.key" -sha384 -days 3650 -subj "/CN=Infinibay Root CA/O=Infinibay" -out "$PKI/ca/ca.crt"
CA_FP=$(openssl x509 -in "$PKI/ca/ca.crt" -noout -fingerprint -sha384 | sed 's/.*=//;s/://g' | tr A-Z a-z)
sed -i "s/^INFINIBAY_CA_FINGERPRINT=.*/INFINIBAY_CA_FINGERPRINT=$CA_FP/" "$ENV_FILE"   # printed for --ca-fp
```

**CA under N-replica HA (resolves Control-Plane §6 vs single-CA-key invariant).** `ca.key` lives on **exactly one designated host** (`/var/lib/infinibay/pki/ca/ca.key`, `0400 root`, never in DB, never over RPC). All signing — `approveNode`, `rotateNodeCert`, CRL re-issue — is **leader-gated** via the same `pg_advisory_lock` leader election Control-Plane §6 defines: only the lock-holding replica performs CA operations. A replica that does not hold `ca.key`/leadership **proxies the signing mutation to the leader** (internal mТLS) or returns `retryable: LEADER_ONLY`; it never holds a second copy of the crown jewel. Agents pin the **CA**, and **every replica serves the same master server cert** (one leaf, `SAN = LB VIP + replica IPs`, issued from the CA) so OOB CA pinning holds uniformly behind the load balancer regardless of which replica terminates the connection.

**Signing on approve**: sign leaf, EKU `clientAuth`, SAN URI `infinibay://node/<nodeId>`, `notAfter = now+90d`, monotonic serial; persist `certPem`, `fingerprint`, `certSerial`, and `NodeUnderlay.vtepIp = JoinRequest.underlayIp`.

**Storage**: node private key → `/etc/infinibay/agent/agent.key` `0600 root` (never transmitted; only the CSR leaves the node). Master keeps signed leaves in `Node.certPem`; CA key on disk on the CA host only.

**Rotation / renewal**: 90d leaves + `rotateNodeCert` over the already-authenticated mTLS channel (node proves possession of current key → fresh leaf, no human, no re-pairing). Agent auto-renews at 2/3 lifetime. CA rotation = generate CA′, cross-sign, push new chain over the channel, re-print `masterCaFp′` for any future joins, retire CA after all leaves migrate.

**Revocation / decommission — positive fencing, not just CRL.** CRL + short TTL only blocks *future* handshakes; a compromised or simply uncooperative agent will not voluntarily tear down its QEMU, and under agent-push liveness the master has no command channel into a rogue node. `decommissionNode` (and the master's malicious-node detection path) therefore **must invoke positive STONITH fencing before declaring the node removed**, reusing the machinery **Observability-Ops §3** owns:
1. **Storage eviction** — Ceph RBD `blocklist add` for the node's client + drop its `exclusive-lock`; for NFS/iSCSI, break the node's locks. Prevents concurrent-writer corruption of any shared qcow2 the master may re-home elsewhere.
2. **Network quarantine** — drop the node's VTEP from every department FDB and revoke its overlay membership (**Networking**), so a still-running rogue VM is isolated.
3. **Power fence** — BMC/IPMI or PDU power-off where wired.

Only after fencing succeeds (or is confirmed impossible and the node is storage+network isolated) does the master add the serial to the CRL and set `status='decommissioned'`. G0 `nodeId`-scoping (infinization) ensures a revoked node cannot reap *other* nodes' VMs, but it does **not** stop a rogue node mauling its own tenants' data or pinning shared storage — fencing is what closes that. A cooperative agent additionally self-tears-down on CRL/handshake failure, but the design never depends on its cooperation.

### 8. Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| CA-FP mismatch at node | node derives ≠ `--ca-fp`/OOB value | node aborts before pinning; no cert installed — suspected MITM, alert |
| Pending row expires | `sasExpiresAt` passed | node re-runs `join` (new nonce/keypair); cron prunes expired `pending` |
| mDNS unavailable / segmented LAN | browse timeout | `--master <ip> --ca-fp <fp>` manual fallback |
| Duplicate `proposedName` | unique check at create | append suffix / admin rename before approve |
| `approveNode` on non-leader replica | no `ca.key` | proxy to leader / `LEADER_ONLY` retryable |
| Node key compromise | out-of-band | `decommissionNode` → fence (§7) + CRL + status flip; reimage + re-join |
| Decommissioned node keeps running VMs | agent uncooperative / lease lost | positive fencing: storage blocklist + FDB eviction + power fence (Obs-Ops §3) |
| CA key compromise | — | rotate CA (cross-sign), re-issue leaves, re-print `masterCaFp`, revoke old CA |
| `/node/join` flooding | rate-limiter | per-IP throttle + pending-row cap; OOB pinning makes forged joins inert |

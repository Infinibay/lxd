## Deployment, Installer & Cluster Lifecycle

Redesigns the `lxd` installer (`setup.sh`, `run.sh`, `envs/`, `profiles/templates/`, `provisioning/`) so a single repo installs **both** the master control plane and any number of compute nodes, with a one-command join. The current single-host path (`./run.sh` with no args → `smart_default`, `run.sh:569`) is preserved bit-for-bit: **master is just a 1-node cluster**.

### 1. Install roles

A node's role is the only new global input. It is persisted in `/etc/infinibay/role` and echoed into the values file so every subsequent `run.sh` invocation is role-aware without re-asking.

| | **master** (default) | **node** |
|---|---|---|
| Containers deployed | `infinibay-postgres`, `-backend`, `-frontend` (today's `envs/infinibay.yml`) | `infinibay-node` only (`envs/infinibay-node.yml`) |
| Extra services | mTLS **CA**, mDNS advertise `_infinibay-master._tcp`, local node row (`role="master"`, `address=127.0.0.1`) | Node Agent + local `infinization` + QEMU/KVM |
| Postgres / GraphQL / Frontend | yes | **no** |
| Secrets generated | `DB_PASSWORD`, `ADMIN_PASSWORD`, `TOKENKEY`, `INFINISERVICE_HMAC_MASTER_SECRET` (`setup.sh:401-409`) + new `CA` keypair | **none of the above** — node holds only its own mTLS identity |
| Provisioning | `provisioning/provision-all.sh` (unchanged) | new `provisioning/node.sh` |

Both roles still deploy through LXD + lxd-compose: a compute node is one LXD container with `/dev/kvm` passthrough + `security.nesting` — the **exact** container model the backend already uses (KVM passthrough in `profiles/templates/infinibay-backend.yml:9-17`; the `security.nesting` flag in `envs/infinibay.yml:83`). See **ADR-D1**.

**Secret-distribution invariant (authoritative; see §8 and ADR-D5).** The `INFINISERVICE_HMAC_MASTER_SECRET` is a **master-only fleet secret**. It is generated once at master bootstrap, lives only in the master's root-only systemd `EnvironmentFile`, and is **never** written to any compute node's environment, container, or disk. This section owns the host→guest credential-distribution model; any subsystem spec that places the master HMAC secret on every node (the rejected "fleet-wide EnvironmentFile on every host" approach) is superseded by this invariant — derive per-VM keys instead (§8).

### 2. UX — one command per role

```bash
# MASTER (unchanged default; now also bootstraps CA + mDNS)
sudo ./setup.sh                 # or  ./setup.sh --role master
./run.sh                        # smart_default → today's 3-container stack + local agent

# NODE (the new path — must be trivial)
sudo ./setup.sh --role node     # installs kvm/lxd/lxd-compose + node container deps, NO postgres/frontend
./run.sh join                   # mDNS-discovers master, pairs, comes online
./run.sh join --master 192.168.1.50   # explicit master (no mDNS / segmented LAN / air-gapped)
./run.sh join --upgrade         # re-provision THIS node in place (rolling upgrade; §8)
```

`setup.sh` gains argument parsing in `main()` (`setup.sh:533`); the node branch skips `install_dependencies`' frontend/postgres packages, skips `check_env_file`'s master `.env`, and instead writes `values-node.yml` (`NODE_NAME`, `MASTER_ADDR`, `AGENT_PORT=9443`, discovered `CA_FP`). `run.sh` gains a `join` case in the dispatcher at `run.sh:567` that now parses an `--upgrade` flag and a `--master <ip>` flag positionally:

```bash
join|j)
    require_role node
    UPGRADE=0; MASTER_ARG=""
    shift
    while [[ $# -gt 0 ]]; do case "$1" in
        --upgrade)  UPGRADE=1 ;;
        --master)   MASTER_ARG="$2"; shift ;;
        *)          echo "join: unknown arg $1" >&2; exit 2 ;;
    esac; shift; done
    discover_master "$MASTER_ARG"          # mDNS browse _infinibay-master._tcp, or --master IP
    ensure_data_dirs_node                  # /var/lib/infinibay/node/<NODE_NAME>/{data,disks}
    setup_profiles                         # now also renders infinibay-node.yml
    sg lxd -c "LXD_DIR=$LXD_DIR lxd-compose apply infinibay-node"
    # --upgrade reuses the EXISTING signed cert under /data/pki (no re-pairing);
    # a first-time join runs the full pairing handshake (Onboarding subsystem).
    sg lxd -c "bash '$SCRIPT_DIR/provisioning/node.sh' ${UPGRADE:+--upgrade}"
    ;;
```

`discover_master` resolves the master, prints `Maestro encontrado: infinibay-master (IP:9443)` and the advertised CA fingerprint for the operator to eyeball. The pairing/double-verification handshake itself is owned by the **Onboarding** subsystem; the installer only triggers it and reports the verification code to the terminal. On `--upgrade` the node already holds a valid cert, so the handshake is skipped and only the container/agent are re-provisioned.

### 3. lxd-compose changes

**`envs/infinibay-node.yml`** — a single parameterized group (vs. the 3 groups in `envs/infinibay.yml:33`). No bridge, no shared storage, no DB env:

```yaml
version: "1"
template_engine: { engine: "mottainai" }
projects:
  - name: "infinibay-node"
    vars:
      - envs:
          INFINIBAY_ROLE: "agent"
          NODE_NAME:    "{{ .Values.NODE_NAME }}"
          MASTER_ADDR:  "{{ .Values.MASTER_ADDR }}"
          AGENT_PORT:   "{{ .Values.AGENT_PORT }}"
          INFINIBAY_DATA_DIR: "/data"
    groups:
      - name: "node"
        connection: "local"          # local host == recommended; remote endpoint == advanced (§5)
        common_profiles: [default, infinibay-base]
        nodes:
          - name: "infinibay-node"   # one agent container per physical host
            image_source: "24.04"
            image_remote_server: "ubuntu"
            profiles: [infinibay-node]
            config: { security.nesting: "true", limits.cpu: "{{ .Values.NODE_CPU_LIMIT }}", limits.memory: "{{ .Values.NODE_MEMORY_LIMIT }}" }
```

**`profiles/templates/infinibay-node.yml`** — KVM passthrough + agent proxy, parameterized:

```yaml
name: infinibay-node
description: Infinibay compute node (local QEMU/KVM via infinization)
config: {}
devices:
  node-data:   { type: disk, source: {{INFINIBAY_DIR}}/node/{{NODE_NAME}}/data,  path: /data }
  node-disks:  { type: disk, source: {{INFINIBAY_DIR}}/node/{{NODE_NAME}}/disks, path: /var/lib/infinization/disks }
  kvm:         { type: unix-char, source: /dev/kvm,       path: /dev/kvm }
  vhost-net:   { type: unix-char, source: /dev/vhost-net, path: /dev/vhost-net }
  agent-proxy:                       # mirrors backend's http-proxy (infinibay-backend.yml:13-17)
    type: proxy
    listen: tcp:0.0.0.0:{{AGENT_PORT}}
    connect: tcp:127.0.0.1:{{AGENT_PORT}}
    bind: host
```

`generate_profile` (`run.sh:90`) only substitutes `{{INFINIBAY_DIR}}` today; extend it to also resolve `{{NODE_NAME}}`, `{{MASTER_ADDR}}`, `{{AGENT_PORT}}` from the values file (no-op for master profiles, which contain none of those tokens — so `setup_profiles`/`run.sh:98` stays backward-compatible):

```bash
generate_profile() {
    sed -e "s|{{INFINIBAY_DIR}}|${INFINIBAY_DIR}|g" \
        -e "s|{{NODE_NAME}}|${NODE_NAME:-}|g" \
        -e "s|{{MASTER_ADDR}}|${MASTER_ADDR:-}|g" \
        -e "s|{{AGENT_PORT}}|${AGENT_PORT:-9443}|g" \
        "$1" > "$2"
}
```

### 4. CA bootstrap (master) and CA topology under HA

Added to the master `setup.sh` path, right after secret generation (`setup.sh:409`). Private key never leaves the master; only the cert + fingerprint are advertised. The node receives a CA-signed client cert during pairing — it never sees `ca.key`. See **ADR-D4**.

```bash
bootstrap_ca() {                       # idempotent
  local PKI=/var/lib/infinibay/pki
  install -d -m 0700 "$PKI"
  [[ -f $PKI/ca.key ]] && return 0
  openssl ecparam -genkey -name prime256v1 -out "$PKI/ca.key"
  openssl req -x509 -new -key "$PKI/ca.key" -sha256 -days 3650 \
    -subj "/CN=Infinibay-CA/O=Infinibay" -out "$PKI/ca.crt"
  # Master SERVER cert SAN = the LB VIP (not a per-replica hostname) so agent
  # pinning holds across ALL replicas behind the load balancer (ADR-D4).
  openssl req -newkey ec:<(openssl ecparam -name prime256v1) -nodes \
    -keyout "$PKI/master.key" -subj "/CN=infinibay-master" \
    -addext "subjectAltName=DNS:infinibay-master,IP:${MASTER_VIP}" \
    -out "$PKI/master.csr"
  openssl x509 -req -in "$PKI/master.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" \
    -CAcreateserial -days 825 -copy_extensions copy -out "$PKI/master.crt"
  openssl x509 -in "$PKI/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2 > "$PKI/ca.fp"
  chmod 0600 "$PKI"/*.key
}
```

**HA reconciliation (resolves the "N replicas vs. one CA host" finding).** Under the Control-Plane §6 multi-replica HA model the CA is **not** replicated:

- `ca.key` physically resides on **exactly one** designated host: `/var/lib/infinibay/pki/ca.key` (root, `0600`, never in DB), identical to single-host. ADR-D4's "only on the master" invariant is preserved unchanged — the crown jewel exists in exactly one place regardless of replica count.
- **All replicas share the same master SERVER cert/key** (`master.crt`/`master.key`, SAN = LB VIP), distributed once at provisioning. Agents pin the LB VIP + CA fingerprint, so the pin holds against any replica the LB routes them to. The server **identity** is fleet-wide; the **signing capability** is not.
- **Signing is leader-gated.** `approveNode` and `rotateNodeCert` are the only operations needing `ca.key`. They acquire the same `pg_advisory_lock` leader token used by Control-Plane §6 reconciliation; only the leader (the replica co-located with `ca.key`) executes the `openssl x509 -req` sign step. A non-leader replica that receives the GraphQL mutation **proxies the CSR-signing call to the leader over the internal mTLS RPC** and returns the signed cert; if the leader is unreachable it **rejects with a retryable `CA_UNAVAILABLE` error** rather than holding a second copy of `ca.key`. CSR validation/policy runs on any replica; only the raw sign is pinned.

This keeps a single crown-jewel host while letting N stateless replicas serve all other traffic. See **ADR-D4** (revised).

### 5. Node on a different physical machine

- **Recommended (local push-by-operator):** the operator runs `sudo ./setup.sh --role node && ./run.sh join` **on the new machine**. `connection: "local"` in `infinibay-node.yml` targets that host's own LXD. Simplest, no cross-host LXD trust, works behind NAT. This is the documented default.
- **Advanced (remote LXD endpoint):** the master operator adds the new host as an LXD remote (`lxc remote add node-2 …`) and sets `connection:` to that remote so `lxd-compose apply` provisions the container over the network. Reserved for fleets already managing LXD remotes centrally. See **ADR-D3**.

### 6. `provisioning/node.sh`

Sibling to `backend.sh`/`provision-all.sh`, run via `lxc exec infinibay-node` (same pattern as the master provisioners). Accepts `--upgrade` (skip keypair/pairing, reuse existing cert). Steps, all idempotent:

1. Install Node + qemu/kvm + `@infinibay/infinization` deps (no Prisma migrate, no Postgres client).
2. `mkdir -p /var/lib/infinization/disks`; assert `/dev/kvm` is a char device (fail fast otherwise).
3. **First join only:** generate agent keypair + CSR (`CN=<NODE_NAME>`); pin the master CA fingerprint from `values-node.yml`. **`--upgrade`:** skip — reuse `/data/pki`.
4. **First join only:** drive the join/pairing handshake (Onboarding subsystem); persist signed cert + master server FP under `/data/pki`.
5. Install/refresh systemd unit `infinibay-node-agent` (`Restart=always`, `INFINIBAY_ROLE=agent`, binds `127.0.0.1:$AGENT_PORT`, exposed via the proxy device), `enable --now`. The unit also arms a **softdog/hardware watchdog** (§7) so a wedged agent self-fences.
6. Mark provisioned via the same LXD-metadata mechanism `check_provisioned` reads (`run.sh:175`).

### 7. Host lifecycle state machine + liveness

```
 uninstalled ──setup.sh --role node──▶ installed ──run.sh join──▶ pending(pairing)
                                                                       │ approveNode (master UI)
                                                                       ▼
        decommissioned ◀──drain+decommission── maintenance ◀─cordon─ online ⇄ offline
                ▲                                   │ (lease-renewal heartbeat; §7)
                │  decommissionNode(id)+confirmFence (dead/partitioned node, §8)
                └──────────── drain (migrate VMs away) ◀── uncordon ─┘
```

This host-level machine complements `Node.status` (`pending→approved→online→offline/decommissioned`) owned by the Data-Model subsystem; the installer drives the `uninstalled↔installed↔pending` and `→decommissioned` edges.

**Liveness model (resolves the heartbeat-direction finding).** Infinibay uses **agent-push lease-renewal heartbeat**, not master-pull. The agent periodically renews a lease on the master over the authenticated mTLS RPC; each heartbeat carries `{ nodeId, agentVersion, vms[] }` and `nodeId`/`vms[]` are **bound to the mTLS client-cert identity** (the master rejects a heartbeat whose `nodeId` ≠ cert CN — see the node-scoping/G0 work). This direction is **load-bearing for corruption-safety**: the agent self-fences when it cannot renew, enforcing the inequality

```
AGENT_SELFFENCE_AT  <  MASTER_DECLARE_DEAD
   (e.g. 15 s)            (e.g. 30 s)
```

so a partitioned-but-alive node **stops its own QEMU/QGA writers before** the master declares it dead and reassigns/restarts its VMs elsewhere — the only mechanism preventing shared-storage double-writes after a partition (the no-double-run proof in Observability §1/ADR-2). A master-pull model is **explicitly rejected** because it provides no agent-side renewal and therefore no self-fence trigger. A hardware/softdog watchdog (armed in §6 step 5) backs this: if the agent process wedges and cannot self-fence in software, the watchdog reboots the host. See **ADR-D5**; Control-Plane §7/ADR-CP4 is revised to match this direction.

### 8. Cluster lifecycle operations

- **Add node:** §2 (`setup.sh --role node` + `run.sh join`). Capacity-based placement (`NodePlacementService`) picks it up once `status='online'`.
- **Remove / decommission — graceful (node alive, operator has shell):** `./run.sh decommission` on the node — **first** cordon (`setNodeMaintenanceMode`) and drain (migrate VMs off via the Migration subsystem), **then** `lxc stop/delete infinibay-node`, wipe `/var/lib/infinibay/node/<NODE_NAME>`. Master-side `decommissionNode(id)` revokes the cert and frees the row. Guard: refuse host teardown while the node still owns running `Machine` rows (prevents orphaning VMs — ties into the **G0** node-scoping landmine).
- **Remove / decommission — dead or partitioned (no node shell possible):** a dead node **cannot** run `./run.sh decommission`, so there is a distinct **master-side runbook** with **no node access required**:
  1. Master/operator triggers fence; Observability's fence path attempts STONITH (LXD/IPMI/watchdog-expiry) and the operator/automation calls **`confirmFence(nodeId)`** to assert the node's writers are provably stopped (watchdog window elapsed or power confirmed). This confirmFence step is the **same one** Observability defines for dead-node fencing — it is now wired directly into decommission.
  2. Only after `confirmFence` succeeds, the master calls **`decommissionNode(nodeId)`**: revoke the node cert (CRL/short-TTL), reassign or restart its `Machine` rows on surviving nodes via Migration, mark `Node.status='decommissioned'`, and free the row. No `lxc` call against the dead host is attempted; its container/disks are reclaimed lazily if/when the host returns (a returning decommissioned node fails cert validation and must re-`join` fresh).

  ```
  dead node ──fence(STONITH)──▶ confirmFence(nodeId) ──▶ decommissionNode(nodeId)
                                   (writers proven        (revoke cert, reassign
                                    stopped)               Machines, free row)
  ```
- **Upgrade ordering:** **control plane first** (RPC kept backward-compatible; master version ≥ node version is the enforced skew policy), then a **rolling, one-node-at-a-time** node upgrade: cordon → drain → `git pull && ./run.sh join --upgrade` (re-provision container, reuse existing cert, restart agent — §2/§6) → uncordon. The agent reports `agentVersion` on the lease-renewal heartbeat (§7) so the master refuses to admit a node newer than itself.
- **Config/secret distribution (authoritative model; resolves the HMAC finding):** master is the sole source of truth. Nodes receive **only** their mTLS identity (signed cert + pinned master FP). `DB_PASSWORD`, `TOKENKEY`, and `INFINISERVICE_HMAC_MASTER_SECRET` **never** land on a node. Instead, per-VM guest credentials are **derived on the master** as `vmKey = HMAC(INFINISERVICE_HMAC_MASTER_SECRET, vmId)` and pushed **just-in-time over the authenticated mTLS RPC** to the node(s) currently hosting that VM:
  - at **VM-create** time, to the placement-chosen node;
  - at **migration** time, the same derived `vmKey` is shipped to the **destination** node JIT (this is what makes migration work *without* the master secret on nodes — the guest's baked-in secret still verifies because the destination receives the identical derived key).

  A compromised node therefore holds only the derived keys for the VMs it currently hosts; it **cannot** read the DB, cannot recover `INFINISERVICE_HMAC_MASTER_SECRET`, and cannot forge host→guest commands for any VM it does not host. **Blast radius is exactly its own VMs** — consistent with the fleet-wide ADR-S3 promise. The alternative of placing the master secret on every node is **rejected**: it makes one node compromise equivalent to fleet-wide host→guest forgery, breaking the "leaked guest secret forges for exactly one VM" property. Key-derivation/rotation mechanics are owned by the **Security-RBAC** subsystem, which must adopt this per-VM-derived model rather than the master-secret-on-every-node model.
- **Air-gapped:** skip mDNS (always `--master IP`), enter the CA fingerprint manually instead of reading the mDNS TXT record, point `image_remote_server` at an internal simplestreams mirror, and pre-stage Node/qemu/infinization packages on a local apt/npm mirror. CA cert and the node tarball are copied in by hand; no internet egress required.

### ADRs

**ADR-D1 — Node deployed as one LXD container per host.** *Decision:* reuse the `infinibay-backend` container shape (KVM passthrough `infinibay-backend.yml:9-17` + `security.nesting`, set today at `envs/infinibay.yml:83`) for `infinibay-node`. *Rationale:* identical isolation/packaging story, no second deployment mechanism, `infinization` already runs nested in a container today. *Rejected:* bare-metal host process (loses LXD packaging/upgrade tooling and the proxy-device port model). *Consequence:* one agent per physical host; multi-tenant-per-host is out of scope.

**ADR-D2 — Separate `envs/infinibay-node.yml` instead of conditional groups in `infinibay.yml`.** *Rationale:* keeps the master env (`envs/infinibay.yml`) untouched and the single-host path provably unchanged; lxd-compose has no native conditionals. *Rejected:* one env with templated group enable/disable (fragile, couples the two install paths). *Consequence:* two small envs to maintain; shared profiles via `common_profiles`.

**ADR-D3 — Local `setup.sh` is the recommended remote-provisioning path.** *Rationale:* avoids cross-host LXD trust setup, works behind NAT, matches the existing operator mental model. *Rejected as default:* central remote-LXD push (kept as an advanced option for fleets already running LXD remotes). *Consequence:* the operator needs shell on each new node once.

**ADR-D4 — CA private key lives on a single host; HA replicas share a server identity, signing is leader-gated.** *Decision:* `ca.key` exists on exactly one host (`/var/lib/infinibay/pki/ca.key`, root `0600`, never in DB), even under N-replica HA. All replicas share one master server cert/key (SAN = LB VIP) so agent pinning holds against any replica. CSR signing (`approveNode`/`rotateNodeCert`) is gated by the §6 `pg_advisory_lock` leader; non-leader replicas proxy the sign to the leader or reject `CA_UNAVAILABLE`. *Rationale:* nodes are stateless executors; a `ca.key` on a node (or copied to every replica) lets a single compromise mint trusted identities. Keeping one CA host preserves the crown-jewel-in-one-place invariant while N replicas still serve all non-signing traffic. *Rejected:* (a) `ca.key` on every replica — multiplies crown-jewel exposure; (b) external KMS/HSM for v1 — deferred as over-scoped. *Consequence:* CSR signing requires the leader replica online; cert re-issue blocks during a leader failover until a new leader acquires the advisory lock and the host with `ca.key` is reachable.

**ADR-D5 — Agent-push lease-renewal heartbeat (not master-pull).** *Decision:* the agent renews a lease on the master each interval (mTLS RPC, payload bound to cert identity) and **self-fences** if it cannot renew within `AGENT_SELFFENCE_AT`, which is strictly less than the master's `MASTER_DECLARE_DEAD`. A softdog/hardware watchdog backs the software self-fence. *Rationale:* a partitioned-but-alive node must stop its own writers before the master reassigns its VMs, or shared storage is double-written and corrupted; only an agent-initiated renewal gives the node a trigger to self-fence. *Rejected:* master-pull polling — provides no agent-side renewal and thus no self-fence, removing the sole anti-double-write mechanism. *Consequence:* nodes need a reliable local timer + watchdog; Control-Plane §7/ADR-CP4 is rewritten to this direction; the inequality `AGENT_SELFFENCE_AT < MASTER_DECLARE_DEAD` is a tuned, tested invariant.

# Infinibay — LXD deployment & Docker/Podman dev stack

Self-hosting and development for the **Infinibay** VDI platform — the backend API,
the web UI, and the QEMU/KVM VM hypervisor. This repo ships **two independent ways
to run the stack**:

| Path | Command | Use it for |
|------|---------|------------|
| 🐳 **Docker / Podman dev stack** | `./dev.sh up` | **Day-to-day development** — one command, hot-reload, clones the app repos and bind-mounts them |
| 📦 **LXD deployment** | `sudo ./setup.sh` → `./run.sh` | **Self-hosting** — LXD system containers, systemd services, `/dev/kvm` passthrough |

Both drive the same Infinibay repos (`backend`, `frontend`, `infinization`,
`infiniservice`) and both run real VMs on a Linux host with `/dev/kvm`.

- Dev-stack details → **[docker/README.md](./docker/README.md)**
- LXD install walkthrough → **[INSTALL.md](./INSTALL.md)**

---

## 🐳 Docker / Podman dev stack (`dev.sh`)

One-command, hot-reload dev environment on **Docker or rootless Podman**. It clones
the app repos into `./repos/`, bind-mounts them into the containers, and reloads on
save — edit code, the stack picks it up live.

```bash
./dev.sh up                  # clone repos + build images + start as the cluster MASTER (live logs)
./dev.sh up -d               # detached
./dev.sh up --cluster        # + emulate compute nodes (node-1/node-2) on this host
./dev.sh down [-v]           # stop (-v also drops volumes: db, node_modules, …)
./dev.sh logs [service]      # follow logs
./dev.sh pull                # fast-forward every repo to origin/main (keeps local edits)
./dev.sh build-infiniservice # cross-compile the in-guest agent (see note below)
./dev.sh status | restart | clean

# Multi-node — run ON A SECOND physical host to add it as a compute node:
./dev.sh join http://<master-ip>:4000   # SAS pairing, then start the node agent
./dev.sh node up|down|logs|status|restart   # manage that node agent afterwards
```

`make up`, `make down`, `make logs S=backend`, … wrap the same commands. First `up`
clones the repos and installs all deps **inside** the containers (a few minutes, once).

Once up:
- Frontend → <http://localhost:3000>
- Backend GraphQL → <http://localhost:4000/graphql>
- Postgres → `localhost:5432` (user/db/pass `infinibay`)

### Key operational notes

- **KVM is auto-detected.** On Linux with `/dev/kvm`, VMs are enabled automatically
  (force with `--kvm` / `--no-kvm`, or `KVM=on|off`). Without `/dev/kvm` (e.g. macOS)
  it runs control-plane-only — the whole UI/API/DB works, VM create/start does not.
- **Rootless Podman is supported.** The KVM override grants the backend container
  `/dev/kvm` via Podman's `keep-groups`, so **your host user must be in the `kvm`
  group** (`sudo usermod -aG kvm $USER`, then re-login).
- **Guest VMs need `infiniservice`.** During install, a guest downloads the in-guest
  agent from the backend at `http://<gateway>:4000/infiniservice/{linux,windows}/binary`.
  That agent is a Rust binary that is **not built by `up`** — run
  **`./dev.sh build-infiniservice` once** (it cross-compiles the Linux ELF + Windows
  `.exe` into the shared volume the backend serves). Skip it and installs fail
  mid-way with a 404 fetching the agent. Re-run it after `down -v` / `clean`, which
  wipe that volume.
- **`up` clones missing repos but does NOT update existing checkouts** — use
  `./dev.sh pull` to advance them to `origin/main` (it skips any repo with
  uncommitted changes, so it never clobbers your edits).
- **Multi-node:** this stack always comes up as the cluster **master**. `--cluster`
  adds emulated `node-1`/`node-2` heartbeats on this same host; to add a **real second
  host**, run `./dev.sh join http://<master-ip>:4000` there — see below.

### Multi-node: run a master + add real compute nodes

The dev stack can span **more than one physical host**: one master plus N compute
nodes, each onboarded with a SAS-verified pairing (the same ceremony as the LXD
`./run.sh join`, wrapped for Docker/Podman).

**1 — The master.** Nothing extra: `./dev.sh up` on this host already **is** the
master. It seeds a cluster bootstrap token into `.env.docker`. Note the master's LAN
IP (`hostname -I` on the master, or the "reachable from other devices" line that `up`
prints) — the node needs it.

**2 — Get the cluster token** (the node needs it — it's a shared secret you choose,
not something issued). On the **master**:

```bash
grep INFINIBAY_CLUSTER_TOKEN .env.docker        # dev default: dev-insecure-cluster-token
```

For a real cross-host cluster, rotate it to a strong value and reload the master:

```bash
NEW=$(openssl rand -hex 32)
sed -i "s/^INFINIBAY_CLUSTER_TOKEN=.*/INFINIBAY_CLUSTER_TOKEN=$NEW/" .env.docker
./dev.sh up -d                                  # recreate the backend so it picks up $NEW
```

**3 — Join, on the SECOND host.** Clone this repo there and run `join` with the
master's IP:

```bash
git clone https://github.com/Infinibay/lxd && cd lxd
./dev.sh join http://<master-ip>:4000           # a bare IP also works → http://<ip>:4000
#   non-interactive:  ./dev.sh join http://<master-ip>:4000 --name worker-1 --token <token>
```

`join` clones `backend` + `infinization`, offers the token from `.env.docker` (paste
the master's if it differs), then prints a **6-digit pairing code**. Approve it in the
master UI (**Infrastructure**) — the codes must match. On approval it starts the node
agent and the node reports **online**. (Run `./dev.sh join` with no URL and it prompts
for the master IP.)

**4 — Run / manage the node** after joining (config is saved in `.env.node`):

```bash
./dev.sh node up          # start (levantar) the node agent
./dev.sh node logs        # follow its logs
./dev.sh node status      # ps
./dev.sh node down        # stop it
```

Use `./dev.sh join --no-start` to enrol **without** starting, then `./dev.sh node up`
whenever you want to bring it up.

**Notes**
- **You supply the master URL** (`./dev.sh join http://<master-ip>:4000`, or a bare IP
  → `http://<ip>:4000`). There is **no LAN auto-discovery**: onboarding is a trust
  boundary, so the endpoint is explicit and verified via the pairing code — the same
  model as k3s / Docker Swarm / kubeadm joins, and it works across routed networks.
- **Heartbeat auth** defaults to **mTLS** (a real remote node exists to receive migrated
  VMs, and the disk copy is mTLS-only). Pass `--no-mtls` to drop to the dev token channel
  (same-host emulation, or a master still in token mode) — migration won't work then.

### Moving VMs to a node (cross-node cold migration)

To actually **migrate a (stopped) VM onto a remote node**, the cluster must run in
**mTLS** mode (the disk copy is mTLS-only) and the node needs **KVM** to boot it:

```bash
# MASTER — run with mTLS (starts + publishes the :4433 ops server; persisted to .env.docker):
./dev.sh up --kvm --mtls

# NODE — join (mTLS by default) + KVM (serves HTTPS on :9443, reachable ops channel, can boot VMs):
./dev.sh join http://<master-ip>:4000 --kvm
#   approve the SAS in the master UI (Infrastructure)
```

Then in the UI, migrate a **stopped** VM to the node (or `migrateMachineToNode`). The
master copies the disk to the node over mTLS, flips ownership, and VM start/stop dispatch
to the node's agent. Notes:

- **`--mtls` is cluster-wide all-or-nothing** — with it on, token-mode nodes and the
  same-host `--cluster` emulation are retired (HTTP 421). `dev.sh` refuses `--mtls` +
  `--cluster` together. `--mtls` is **persisted** in `.env.docker`, so later `up` runs
  stay in mTLS mode.
- **`--kvm` on the node is opt-in** and, under rootless podman, switches it to **rootful**
  (sudo) — a *different* volume namespace. If you first joined **without** `--kvm`, tear
  the node down (`./dev.sh node down`) and re-join with `--kvm` (fresh enrollment).
  Requires `/dev/kvm` and your node-host user in the `kvm` group.
- **Disk dir is unified** at `/opt/infinibay/disks` (a persistent volume) on both master
  and node — cross-node migration pushes the disk's absolute path verbatim. This moved VM
  disks off the old **ephemeral** path: **VMs created before this version have disks on the
  old ephemeral path and are lost on the container recreate** that applies the change —
  recreate them so new disks land in the volume (persistent + migratable).

Current dev-stack version: **v0.6.1** (tracked in `VERSION`).

---

## 📦 LXD deployment (`setup.sh` / `run.sh`)

LXD system containers via **[lxd-compose](https://mottainaici.github.io/lxd-compose-docs/)** —
closer to a real self-hosted install: systemd services, `/dev/kvm` passthrough,
persistent data disks, backup/upgrade tooling.

### Quick start

```bash
# 1. Install LXD + lxd-compose, detect distro/pkg-manager, generate .env with secrets
sudo ./setup.sh

# 2. Activate the lxd group — REQUIRED (setup.sh added you to it)
newgrp lxd                 # or log out and back in

# 3. Review .env — change ADMIN_PASSWORD (setup.sh auto-generated one)
nano .env

# 4. Bring everything up (smart default: create → provision → start; idempotent)
./run.sh
# Prints the frontend (:3000) and backend (:4000/graphql) URLs when ready.
```

`setup.sh` is multi-distro: it auto-detects **apt / dnf / zypper / pacman** and
native-vs-snap LXD, initialises LXD (`lxdbr0` + a `dir` storage pool), and seeds
`.env` with `openssl`-generated secrets.

### Architecture — 3 containers

Defined in `envs/infinibay.yml`:

| Container | Base | Role |
|-----------|------|------|
| `infinibay-postgres` | Ubuntu 22.04 | PostgreSQL (data relocated to `/data/pgdata`) |
| `infinibay-backend`  | Ubuntu 24.04 | Node.js API + `infinization` hypervisor; serves `infiniservice` to guests; `/dev/kvm` passthrough + `security.nesting=true`; proxied on `:4000` |
| `infinibay-frontend` | Ubuntu 22.04 | Next.js UI (production build); proxied on `:3000` |

KVM is delivered by passing the host `/dev/kvm` char device into the backend
container (profile `infinibay-backend`); the backend installs `qemu-kvm`/`qemu-utils`
and joins its user to the `kvm` group. Profiles are templated in
`profiles/templates/`; each container mounts a host `data/<role>` disk at `/data`,
so data survives container recreation.

### `run.sh` commands

Run `./run.sh` with **no arguments** for the smart default: it creates the
environment if missing, starts stopped containers, provisions if not yet
provisioned, and prints the URLs. Safe to re-run — it skips completed steps.

| Command | Aliases | Description |
|---------|---------|-------------|
| *(none)* | — | smart default: create → provision → start |
| `apply` | `a`, `ap` | create + start containers |
| `provision` | `p`, `pr` | install software (`provisioning/provision-all.sh`) |
| `redo` | `rd` | destroy + recreate from scratch |
| `destroy` | `d`, `de` | remove all containers |
| `status` | `s` | container status (`lxc list`) |
| `stop` | `sto` | graceful reverse-order stop (`--force`, `--check-vms`) |
| `update` | `u` | atomic multi-repo update with backup + rollback |
| `upgrade` | `ug` | versioned upgrade (`--list`, `--dry-run`, `<version>`) |
| `backup` | `b`, `bak` | snapshot/backup (`--label`, `--list`, `--clean`, `--enable-schedule`) |
| `join` | `jn` | enroll THIS host as a compute node of a master (see below) |
| `setup-profiles` | `sp` | regenerate LXD profiles only |
| `exec` | `e`, `ex` | `./run.sh exec backend bash` |
| `logs` | `l`, `lo` | `./run.sh logs backend` (journalctl -f) |
| `help` | `--help`, `-h` | usage; `help update\|upgrade\|join` for sub-help |

### Multi-node clustering

`./run.sh join <master-url> <token> [node-name]` onboards **this host as an Infinibay
compute node** of an existing master: a SAS-verified mTLS enrollment that prints a
6-digit pairing code to approve in the master UI, with optional mDNS discovery of the
master (`<master-url> = auto`). This is application-level Infinibay clustering — not
LXD's own cluster feature. (The Docker dev stack offers the same onboarding via
`./dev.sh join`, and emulates several nodes on one host via `./dev.sh up --cluster`.)

---

## Troubleshooting

**LXD path**
- *Permission denied on the LXD socket / "Unable to read the configuration file"* →
  you're not in the `lxd` group yet: `newgrp lxd` (or re-login). Verify with
  `groups | grep lxd`.
- *`lxd-compose` says "No project selected"* → always name the project:
  `lxd-compose apply infinibay`.
- *Provisioning failed / want a clean slate* → `./run.sh redo`.

**Dev stack**
- *VM install can't download infiniservice (`…:4000/infiniservice/... 404`)* → run
  `./dev.sh build-infiniservice` once, then create a **fresh** VM.
- *Rootless Podman: QEMU "Could not access KVM kernel module: Permission denied"* →
  add your user to the `kvm` group and re-login (the compose keeps it via `keep-groups`).
- *Added a dependency but it isn't installed* → installs only run when `node_modules`
  is empty: `docker volume rm infinibay-dev_backend_node_modules`, then `./dev.sh up`.
- *First boot looks stuck* → it's installing deps: `./dev.sh logs backend`.
- *Private repo clone fails* → authenticate first (`gh auth login`).

---

## Repo layout

```
lxd/
├── dev.sh                      # 🐳 Docker/Podman dev stack entrypoint
├── docker-compose.yml          #    base dev stack
├── docker-compose.kvm.yml      #    Linux KVM override (/dev/kvm, keep-groups, NET_ADMIN)
├── docker-compose.cluster.yml  #    multi-node emulation (node-1/node-2, same host)
├── docker-compose.node.yml     #    real cross-host compute node (./dev.sh join)
├── docker-compose.node.kvm.yml #    node KVM overlay (./dev.sh join --kvm; boots migrated VMs)
├── docker/                     #    entrypoints (incl. entrypoint-node-agent.sh) + dev README
├── Makefile                    #    thin wrapper over dev.sh
├── repos/                      #    app repos (cloned by dev.sh, bind-mounted)
│
├── setup.sh                    # 📦 LXD host setup (LXD + lxd-compose + .env)
├── run.sh                      #    LXD management (smart default, provision, join, backup, …)
├── .lxd-compose.yml            #    lxd-compose config
├── envs/infinibay.yml          #    LXD project (3 containers)
├── profiles/templates/         #    LXD profile templates
├── provisioning/               #    per-container provisioning scripts
├── upgrades/                   #    versioned upgrade manifests
└── INSTALL.md                  #    full LXD install guide
```

## References

- [LXD documentation](https://documentation.ubuntu.com/lxd/) ·
  [lxd-compose documentation](https://mottainaici.github.io/lxd-compose-docs/)
- Dev-stack guide: [docker/README.md](./docker/README.md)
- Full LXD install guide: [INSTALL.md](./INSTALL.md)

---

**Last updated:** 2026-07-08 · dev-stack `VERSION` 0.6.1

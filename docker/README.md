# Infinibay — Docker dev environment (Mac / any Docker host)

A one-command, **hot-reload** development stack. You edit the code, the
containers pick it up live. This sits **alongside** the LXD production path
(`setup.sh` / `run.sh`) — it does not replace it.

> **Why Docker here?** Infinibay's services target Linux. On a Mac this gives
> you a Linux runtime for the whole control plane without installing anything
> but Docker Desktop.

## TL;DR

```bash
cd lxd
./dev.sh up          # or: make up
```

First run clones the four repos into `./repos/`, then builds images and installs
all dependencies **inside** the containers (several minutes — only the first
time). Then:

- Frontend → <http://localhost:3000>
- Backend GraphQL → <http://localhost:4000/graphql>
- Postgres → `localhost:5432` (user/db/pass `infinibay`)

Edit anything under `./repos/backend`, `./repos/frontend`, or
`./repos/infinization` and it reloads automatically.

## What runs

| Service     | Image base        | Mode                        | Port |
|-------------|-------------------|-----------------------------|------|
| `postgres`  | `postgres:16`     | data in a named volume      | 5432 |
| `backend`   | `node:20-bookworm`| `ts-node` under **nodemon** | 4000 |
| `frontend`  | `node:20-bookworm`| **`next dev`** (HMR)        | 3000 |
| `infinization` | (in the backend container) | **`tsc --watch`** → rebuilds `dist/` | — |
| `infiniservice-builder` | `rust:1-bookworm` | optional, on demand | — |

`infinization` is a library the backend imports in-process (`file:../infinization`),
so it's built and watched **inside the backend container**, not as its own
service. `infiniservice` is the Rust agent that runs *inside guest VMs* — it is
only ever **built** here (optional profile), never run as a host service.

### Where the build files live

- **`backend/Dockerfile` and `frontend/Dockerfile` live in their own repos** —
  multi-stage, with a `dev` target (used here: source mounted, hot reload) and a
  `prod` target (compiled image, for the future release pipeline). lxd's compose
  just references them with `target: dev`.
- **lxd owns the composition**: `docker-compose.yml`, the KVM override, the
  `docker/entrypoint-*.sh` hot-reload scripts, the `.env.docker` wiring, and the
  `infiniservice` builder image (`docker/infiniservice.Dockerfile`).

## Commands

```bash
./dev.sh up [-d] [--kvm]   # start (detached / with the Linux KVM override)
./dev.sh down [-v]         # stop (-v also deletes volumes: db + node_modules)
./dev.sh logs [service]    # follow logs
./dev.sh pull              # fast-forward every repo to latest main (keeps edits)
./dev.sh restart [service]
./dev.sh status
./dev.sh build-infiniservice   # cross-compile the guest agent
./dev.sh clean             # nuke volumes + built images
```

`make up`, `make down`, `make logs S=backend`, `make pull`, … wrap the same.

## How live-reload works

Source is **bind-mounted** from `./repos/<repo>` into each container.
`node_modules`, `dist/`, and `.next/` live in **named volumes** layered on top —
so installs happen Linux-side (native modules match) and never touch your host
checkout. File watching uses polling (`CHOKIDAR_USEPOLLING` / `WATCHPACK_POLLING`)
because Docker Desktop's filesystem doesn't emit reliable inotify events.

- **Backend**: `nodemon` watches `app/` and `infinization/dist/`, re-running the
  project's own `ts-node` (identical to `npm start`). A change restarts it.
- **Frontend**: `next dev` does true HMR.
- **infinization**: `tsc --watch` keeps `dist/` fresh, which trips the backend's
  nodemon — so editing the hypervisor library also reloads the backend.

Restarts of the backend are a few seconds (cold `ts-node`); that's expected.

## Configuration

Copy `../.env.docker.example` → `../.env.docker` (auto-created on first `up`).
Common knobs: `BACKEND_PORT`, `FRONTEND_PORT`, `POSTGRES_*`, `TOKENKEY`,
`REPOS_DIR`, `REPO_REF`. If you change `BACKEND_PORT`, also update
`NEXT_PUBLIC_*` to match (they're baked into the browser bundle).

Want to use your **existing** sibling checkouts instead of fresh clones? Set
`REPOS_DIR=..` in `.env.docker` (the dir must contain `backend/`, `frontend/`,
`infinization/`, `infiniservice/`).

## The KVM reality (important)

The backend + infinization manage VMs by launching **real QEMU with
`-enable-kvm`** and reconfiguring host networking (nftables, bridges, TAP). That
needs `/dev/kvm`, which **Docker Desktop on Mac (especially Apple Silicon) does
not provide**. So on a Mac:

- ✅ Works: GraphQL API, auth, departments, pools logic, DB, the entire UI,
  real-time events — the whole control plane for development.
- ❌ Does not work: actually creating/starting VMs, per-VM networking, SPICE,
  TPM, snapshots/backups. These log errors but don't crash the API.

To get full VM functionality, run on a **Linux host with KVM** and add the
override: `./dev.sh up --kvm` (grants `/dev/kvm`, `/dev/net/tun`, `NET_ADMIN`).

## Troubleshooting

- **`harbor submodule is missing`** (frontend) → `./dev.sh pull`, or
  `git -C repos/frontend submodule update --init --recursive`.
- **Added a dependency** → installs only run when `node_modules` is empty.
  Force a reinstall: `docker volume rm infinibay-dev_backend_node_modules`
  (or `frontend_node_modules`) then `./dev.sh up`.
- **First boot looks stuck** → it's installing deps; `./dev.sh logs backend`.
- **Port already in use** → change `BACKEND_PORT`/`FRONTEND_PORT`/`POSTGRES_PORT`
  in `.env.docker`.
- **Private repo clone fails** → authenticate first: `gh auth login` (or set up a
  git credential helper for `github.com/Infinibay/*`).

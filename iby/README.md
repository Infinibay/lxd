# iby — Infinibay CLI

`iby` (InfiniBaY) is the canonical tool to **deploy and administer Infinibay**. It
replaces `dev.sh` as the driver for the Docker/Podman dev stack and (in later
phases) the LXD self-hosted install.

> Status: **Phase 0/1 in progress.** `dev.sh` still works and is deprecated.

## Install

```bash
uv tool install infinibay-iby            # isolated, auto-managed venv → `iby` on PATH
# from this repo's subdirectory (pinned):
uv tool install "infinibay-iby @ git+https://github.com/Infinibay/lxd#subdirectory=iby"
# zero-install:
uvx --from infinibay-iby iby doctor
```

Contributors:

```bash
cd iby && uv sync && uv run iby --help
```

## First steps

```bash
iby doctor          # preflight: runtime, compose v2, /dev/kvm, kernel modules, groups
iby up              # bring the dev stack online (Phase 1)
iby --help          # the full command map
```

`iby` shells out to `docker`/`podman`, `compose`, `git`, and (LXD phase) `lxc`/`sg`;
`iby doctor` verifies they are present. It never rewrites the `docker-compose*.yml`
files — it drives them.

## Layout

```
src/iby/
  cli/        thin Typer layer (parse → delegate → render)
  core/       context, process runner, dotenv, console, errors
  runtime/    container-runtime + compose detection, kernel modules, registries
  services/   the reimplemented orchestration logic
  models/     typed enums
  data/       bundled identity engine assets (Phase 1)
```

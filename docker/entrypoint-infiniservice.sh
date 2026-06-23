#!/usr/bin/env bash
# infiniservice builder entrypoint (optional `builders` profile).
# Cross-compiles the guest agent and deploys artifacts into the shared
# infinibay_base volume ($INFINIBAY_BASE_DIR/infiniservice/...) where the
# backend serves them to guests over HTTP. Best-effort; exits when done.
set -uo pipefail

log() { echo -e "\033[1;32m[infiniservice]\033[0m $*"; }
warn() { echo -e "\033[1;33m[infiniservice]\033[0m $*"; }

SVC=/workspace/infiniservice
export INFINIBAY_BASE_DIR="${INFINIBAY_BASE_DIR:-/opt/infinibay}"
mkdir -p "$INFINIBAY_BASE_DIR" 2>/dev/null || true

cd "$SVC"

# Use deploy.sh: it builds both targets and writes the binaries/{linux,windows}/ +
# install/ layout the backend's /infiniservice route actually serves. (We do NOT
# use build-installer.sh --deploy — it deploys to target/release/, which the
# route does not read, and it runs `cargo install cross` + a `zip` step that this
# image doesn't need.) The image is amd64, so the x86_64 Linux build is native.
if [ -f ./deploy.sh ]; then
  log "running ./deploy.sh (Linux ELF + Windows .exe → /opt/infinibay/infiniservice/binaries/…)"
  # 'N' answers deploy.sh's optional Windows code-signing prompt non-interactively.
  printf 'N\n' | bash ./deploy.sh
  rc=$?
elif [ -f ./build-installer.sh ]; then
  warn "deploy.sh missing — falling back to ./build-installer.sh --deploy (wrong binary layout; install scripts only)."
  bash ./build-installer.sh --deploy
  rc=$?
else
  warn "no deploy script found — plain cargo build to verify it compiles."
  cargo build --release
  rc=$?
fi

if [ "$rc" -eq 0 ]; then
  log "done. Artifacts under /opt/infinibay/infiniservice/binaries (served by the backend on :4000)."
else
  warn "build/deploy exited with code $rc — see output above."
fi
exit "$rc"

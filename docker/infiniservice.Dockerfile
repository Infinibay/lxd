# Infinibay infiniservice cross-compile builder (OPTIONAL profile).
#
# infiniservice is the Rust agent that runs INSIDE guest VMs, not a host service.
# This image only BUILDS it: a Windows .exe (via mingw) and a Linux ELF, which
# get deployed into the shared infinibay_base volume for the backend to serve.
#
# Guests are x86_64, so we PIN the image to linux/amd64. On an amd64 host this is
# native; on Apple Silicon (arm64) Docker runs it under QEMU emulation — slower,
# but it produces correct x86_64 guest binaries with no cross-toolchain juggling.
# The Windows .exe is then a normal mingw cross-compile on top of that.
# (You can't run VMs on a Mac anyway, so this builder is a convenience.)
FROM --platform=linux/amd64 rust:1-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      # Windows cross-compile toolchain (deploy.sh builds x86_64-pc-windows-gnu):
      gcc-mingw-w64-x86-64 \
      # native Linux build deps: openssl-sys (reqwest → native-tls) needs these.
      pkg-config \
      libssl-dev \
      build-essential \
      bash \
      git \
    && rm -rf /var/lib/apt/lists/*

RUN rustup target add x86_64-pc-windows-gnu

WORKDIR /workspace/infiniservice

CMD ["bash", "-lc", "echo 'Run via: ./dev.sh build-infiniservice'; sleep infinity"]

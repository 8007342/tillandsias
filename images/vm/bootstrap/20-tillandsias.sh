#!/usr/bin/env bash
# Step 20 — install tillandsias-headless inside the VM rootfs from source.
#
# Builds the canonical Linux musl-static binary FROM source (not downloaded
# from GitHub releases — per owner stance 2026-05-24, Tillandsias ships
# no prebuilt Linux binaries). Source is bind-mounted at /src during the
# recipe build (materialize::macos / ::vfr / ::wsl all pass --volume).
#
# Also installs the systemd unit that runs tillandsias-headless with
# --listen-vsock 42420 on boot (per RECIPE vsock-listen directive in
# Recipefile, interpreted by tillandsias-vm-layer::recipe).
#
# @trace openspec/changes/vm-recipe-provisioning §1.4, §D7

set -euo pipefail

# Pick up the right Rust toolchain (rustup was installed in the base RUN).
export PATH="/root/.cargo/bin:${PATH}"
rustup default stable 2>/dev/null || rustup toolchain install stable
# Cross to the host arch's musl target for max portability — the Linux
# binary is always musl-static per CLAUDE.md "musl-static portable
# Linux native binary" decision.
TARGET_ARCH="$(uname -m)"
RUST_TARGET="${TARGET_ARCH}-unknown-linux-musl"
rustup target add "$RUST_TARGET"

# /src is bind-mounted by the materializer for this build. If absent
# (e.g. someone runs the script outside the recipe context), fall back to
# pulling the source from the host tillandsias repo via git (Phase 4
# concern; placeholder for now).
if [[ ! -d /src/crates/tillandsias-headless ]]; then
    echo "[20-tillandsias] /src not bind-mounted — cannot build tillandsias-headless"
    echo "[20-tillandsias] materializer must pass --volume <repo>:/src"
    exit 1
fi

cargo install \
    --path /src/crates/tillandsias-headless \
    --target "$RUST_TARGET" \
    --root /usr/local \
    --locked

# Install the systemd unit that starts the in-VM headless on boot listening
# on vsock port 42420 (CONTROL_WIRE_VSOCK_PORT). The RECIPE vsock-listen
# directive in the Recipefile triggers materializer-side validation that
# this unit exists.
cat > /etc/systemd/system/tillandsias-headless.service <<'EOF'
[Unit]
Description=Tillandsias headless (in-VM vsock control wire)
After=network-online.target podman.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
KillSignal=SIGTERM
TimeoutStopSec=20s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable tillandsias-headless.service

echo "[20-tillandsias] done — tillandsias-headless installed + systemd unit enabled"

#!/usr/bin/env bash
# @trace spec:opencode-web-session-otp
# Build tillandsias-router-sidecar as a static musl binary and stage it
# into images/router/ so the (single-stage) router Containerfile can COPY
# it into the image, AND the tray's embedded.rs can include_bytes!() it
# for runtime extraction in deployed binaries.
#
# Run by:
#   - src-tauri/build.rs (pre-compile hook for `cargo build`)
#   - scripts/build-image.sh router (defensive re-run before podman build)
#   - manually for first-time setup or when sidecar source changes
#
# Cross-compile via Rust's `x86_64-unknown-linux-musl` target. NO musl-gcc
# or external toolchain required — the target ships its own static linker
# strategy. Verified on Fedora 43 toolbox 2026-04-26: 3.3 MB static-pie
# binary, no host musl install needed.
#
# The staged binary lives under `images/router/tillandsias-router-sidecar`
# (gitignored). build.rs invokes this script when the file is missing or
# the sidecar source is newer than the staged copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="x86_64-unknown-linux-musl"
SIDECAR_DEST="$ROOT/images/router/tillandsias-router-sidecar"

# Ensure the rustup target is installed. Idempotent — fast no-op on
# subsequent runs. If rustup itself is missing, surface the message
# immediately (we can't proceed without it).
if ! command -v rustup >/dev/null 2>&1; then
    echo "[build-sidecar] ERROR: rustup not found in PATH." >&2
    echo "[build-sidecar] Install rustup first: https://rustup.rs/" >&2
    exit 2
fi
if ! rustup target list --installed | grep -q "^${TARGET}\$"; then
    echo "[build-sidecar] Installing rust target ${TARGET}..."
    rustup target add "${TARGET}"
fi

echo "[build-sidecar] cargo build --release --target ${TARGET} --bin tillandsias-router-sidecar"
( cd "$ROOT" && cargo build --release --target "${TARGET}" --bin tillandsias-router-sidecar )

SRC="$ROOT/target/${TARGET}/release/tillandsias-router-sidecar"
if [[ ! -f "$SRC" ]]; then
    echo "[build-sidecar] ERROR: build succeeded but binary not found at $SRC" >&2
    exit 3
fi

# Strip debug symbols — we ship the binary embedded in the tray and
# extracted into a container; a few MB matters.
strip "$SRC" 2>/dev/null || true

mkdir -p "$(dirname "$SIDECAR_DEST")"
cp "$SRC" "$SIDECAR_DEST"
chmod 0755 "$SIDECAR_DEST"

SIZE="$(du -h "$SIDECAR_DEST" | cut -f1)"
echo "[build-sidecar] staged: ${SIDECAR_DEST} (${SIZE})"

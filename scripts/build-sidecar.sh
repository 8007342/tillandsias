#!/usr/bin/env bash
# @trace spec:opencode-web-session-otp
# Build tillandsias-router-sidecar as a static musl binary and stage it
# into images/router/ so the (single-stage) router Containerfile can COPY
# it into the image, AND the tray's embedded.rs can include_bytes!() it
# for runtime extraction in deployed binaries.
#
# Run by:
#   - build.sh / build-osx.sh (before `cargo tauri build`)
#   - scripts/build-image.sh router (defensive re-run before podman build)
#   - manually for first-time setup or when sidecar source changes
#
# DO NOT run from `src-tauri/build.rs`: the nested `cargo build` here
# deadlocks on the workspace target-dir lock held by the parent cargo
# invocation. Verified in v0.1.170.245 when an AppImage build wedged
# during the tillandsias compilation step.
#
# Cross-compile via Rust's `x86_64-unknown-linux-musl` target. NO musl-gcc
# or external toolchain required — the target ships its own static linker
# strategy. Verified on Fedora 43 toolbox 2026-04-26: 2.5 MB stripped
# static-pie binary, no host musl install needed.
#
# The staged binary lives under `images/router/tillandsias-router-sidecar`
# (gitignored).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="x86_64-unknown-linux-musl"
SIDECAR_DEST="$ROOT/images/router/tillandsias-router-sidecar"
# Use a SEPARATE target dir so a nested invocation (e.g. build.rs calling
# this script while the parent cargo holds target/'s lock) cannot deadlock.
# The nested build still benefits from cargo's incremental compilation
# under target-musl/.
SIDECAR_TARGET_DIR="$ROOT/target-musl"

# Staleness check: if the staged binary already exists and is newer than
# every Cargo.toml + every source file in the three relevant crates,
# there is nothing to do — exit fast. This makes the script cheap to
# re-run from build.sh / scripts/build-image.sh / shell hooks.
is_stale() {
    [[ ! -f "$SIDECAR_DEST" ]] && return 0
    local newest
    newest="$(find \
        "$ROOT/crates/tillandsias-router-sidecar" \
        "$ROOT/crates/tillandsias-otp" \
        "$ROOT/crates/tillandsias-control-wire" \
        "$ROOT/Cargo.toml" \
        "$ROOT/Cargo.lock" \
        -type f -newer "$SIDECAR_DEST" -print -quit 2>/dev/null)"
    [[ -n "$newest" ]]
}

if ! is_stale; then
    echo "[build-sidecar] up-to-date: ${SIDECAR_DEST}"
    exit 0
fi

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

# @trace spec:cross-platform
# Windows host (Git Bash / MSYS) has no `cc` in PATH, so the default
# linker probe for the musl target fails with "linker `cc` not found".
# Pin rust-lld + link-self-contained=yes so the cross-link to ELF musl
# works without an external toolchain. Linux/macOS hosts skip this and
# keep using the system cc resolution they have always used.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="rust-lld"
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes"
        ;;
esac

echo "[build-sidecar] cargo build --release --target ${TARGET} --bin tillandsias-router-sidecar"
( cd "$ROOT" && CARGO_TARGET_DIR="${SIDECAR_TARGET_DIR}" \
    cargo build --release --target "${TARGET}" --bin tillandsias-router-sidecar )

SRC="${SIDECAR_TARGET_DIR}/${TARGET}/release/tillandsias-router-sidecar"
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

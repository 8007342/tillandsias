#!/usr/bin/env bash
# @trace spec:opencode-web-session-otp
# Build tillandsias-router-sidecar as a static musl binary and stage it
# into images/router/ so the (single-stage) router Containerfile can COPY
# it into the image, AND the tray's embedded.rs can include_bytes!() it
# for runtime extraction in deployed binaries.
#
# Run by:
#   - build.sh (staged before EVERY compiling dispatch — check/test/build/
#     install/ci/release — via _stage_router_sidecar; the binary is a gitignored
#     build artifact that tillandsias-headless build.rs include_bytes!()s, so it
#     MUST exist before any cargo invocation)
#   - build-osx.sh (before `cargo tauri build`)
#   - .github/workflows/release.yml (built + published as a version-matched,
#     cosign-signed release asset alongside the linux/macos/windows binaries)
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
    # VERSION is included so a build-number bump forces a fresh, version-matched
    # recompile (order 710-w9kc: idempotent + ephemeral local builds; the sidecar
    # is a version-matched release artifact, never a committed blob).
    newest="$(find \
        "$ROOT/crates/tillandsias-router-sidecar" \
        "$ROOT/crates/tillandsias-otp" \
        "$ROOT/crates/tillandsias-control-wire" \
        "$ROOT/Cargo.toml" \
        "$ROOT/Cargo.lock" \
        "$ROOT/VERSION" \
        -type f -newer "$SIDECAR_DEST" -print -quit 2>/dev/null)"
    [[ -n "$newest" ]]
}

if ! is_stale; then
    echo "[build-sidecar] up-to-date: ${SIDECAR_DEST}"
    exit 0
fi

# Ensure the rustup target is installed if rustup is present.
# If rustup is missing or target addition fails (e.g. in containerized forge environments),
# fall back to compiling for the default host target so cargo build/check/test can proceed.
USE_TARGET=true
if ! command -v rustup >/dev/null 2>&1; then
    USE_TARGET=false
elif ! rustup target list --installed | grep -q "^${TARGET}\$"; then
    if ! rustup target add "${TARGET}" 2>/dev/null; then
        USE_TARGET=false
    fi
fi

if [[ "$USE_TARGET" == true ]]; then
    # @trace spec:cross-platform
    # Hosts whose system `cc` cannot drive an ELF link need rust-lld pinned.
    #
    # Windows (Git Bash / MSYS) has no `cc` in PATH at all, so the linker probe
    # fails with "linker `cc` not found".
    #
    # macOS (702-griq, measured 2026-08-12) has a `cc`, which is why it was
    # originally grouped with Linux here — but it is Apple clang driving ld64,
    # which cannot emit ELF and rejects the GNU linker flags rustc passes:
    #   ld: unknown options: --as-needed -Bstatic -Bdynamic --eh-frame-hdr
    #       -z --gc-sections --strip-all
    #   clang: error: linker command failed with exit code 1
    # Since 710-w9kc made this sidecar a REQUIRED build asset
    # (tillandsias-headless/build.rs include_bytes!s it), that link failure
    # means `cargo build` for the whole workspace fails on macOS — not just
    # this crate. Having a `cc` is not the same as having one that can link
    # for the target.
    #
    # Linux keeps the system cc resolution it has always used.
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*|darwin*)
            export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="rust-lld"
            export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes"
            ;;
    esac

    echo "[build-sidecar] cargo build --release --target ${TARGET} --bin tillandsias-router-sidecar --features unix-only"
    ( cd "$ROOT" && CARGO_TARGET_DIR="${SIDECAR_TARGET_DIR}" \
        cargo build --release --target "${TARGET}" --bin tillandsias-router-sidecar --features unix-only )
    SRC="${SIDECAR_TARGET_DIR}/${TARGET}/release/tillandsias-router-sidecar"
else
    echo "[build-sidecar] rustup/musl target not present — building sidecar with host target"
    echo "[build-sidecar] cargo build --release --bin tillandsias-router-sidecar --features unix-only"
    ( cd "$ROOT" && CARGO_TARGET_DIR="${SIDECAR_TARGET_DIR}" \
        cargo build --release --bin tillandsias-router-sidecar --features unix-only )
    SRC="${SIDECAR_TARGET_DIR}/release/tillandsias-router-sidecar"
fi

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

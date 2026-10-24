#!/usr/bin/env bash
# 1804-sccl: the musl release/LTO sidecar builds must not run under the ambient
# RUSTC_WRAPPER. Land run 181 died with "sccache ... (exit status: 254)" on
# `-C linker-plugin-lto --target x86_64-unknown-linux-musl`. A wrapper that
# always exits 254 models that; the build must still succeed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-wrapper.XXXXXX")"
trap 'rm -rf "$work"' EXIT
printf '#!/bin/sh\necho "fake wrapper invoked" >&2\nexit 254\n' >"$work/bad-wrapper"
chmod +x "$work/bad-wrapper"
export RUSTC_WRAPPER="$work/bad-wrapper"
mt="${CARGO_TARGET_DIR:-$ROOT/target}/sidecar-wrapper-musl"; trap 'rm -rf "$work" "$mt"' EXIT
export TILLANDSIAS_SIDECAR_TARGET_DIR="$mt" TILLANDSIAS_SIDECAR_FORCE_REBUILD=1
if "$ROOT/scripts/build-forge-plan-bin.sh" >"$work/out" 2>&1; then
    echo "PASS: forge-plan-bin build ignores RUSTC_WRAPPER"
else
    tail -5 "$work/out" >&2
    echo "FAIL: forge-plan-bin build ran under RUSTC_WRAPPER" >&2
    exit 1
fi

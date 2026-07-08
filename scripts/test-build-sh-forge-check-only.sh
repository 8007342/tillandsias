#!/usr/bin/env bash
set -euo pipefail

# @trace plan/issues/forge-build-check-tooling-gap-2026-07-08.md
# Pin the build.sh forge check-only branch without running a full cargo build.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SH="$ROOT/build.sh"

fail() {
    printf 'forge-check-only test failed: %s\n' "$*" >&2
    exit 1
}

grep -F '_forge_check_only_without_host_podman_setup()' "$BUILD_SH" >/dev/null \
    || fail "missing forge check-only predicate"

grep -F 'Skipping host Podman registry setup for forge check-only build' "$BUILD_SH" >/dev/null \
    || fail "registry setup skip message missing"

grep -F 'Skipping host dev cache setup for forge check-only build' "$BUILD_SH" >/dev/null \
    || fail "dev cache skip message missing"

if grep -F 'for tool in cargo rustc rustfmt clippy-driver gcc pkg-config file;' "$BUILD_SH" >/dev/null; then
    fail "file is still required for all host build checks"
fi

grep -F '[[ "$FLAG_INSTALL" == true ]] && ! command -v file' "$BUILD_SH" >/dev/null \
    || fail "install-only file requirement missing"

bash -n "$BUILD_SH"

printf 'forge-check-only: ok\n'

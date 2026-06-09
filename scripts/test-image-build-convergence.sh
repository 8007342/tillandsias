#!/usr/bin/env bash
# @trace spec:init-incremental-builds, spec:forge-staleness, spec:litmus-framework
# Verify the canonical shell image engine rebuilds only when source digest or
# explicit force requires it. Uses fake, stateful Podman; no containers needed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${1:-proxy}"
CONTAINERFILE="$ROOT/images/$IMAGE_NAME/Containerfile"
if [[ "$IMAGE_NAME" == "forge" ]]; then
    CONTAINERFILE="$ROOT/images/default/Containerfile"
fi

if [[ ! -f "$CONTAINERFILE" ]]; then
    echo "FAIL: unsupported convergence image: $IMAGE_NAME" >&2
    exit 1
fi

tmp="$(mktemp -d)"
original_version="$tmp/VERSION.orig"
original_containerfile="$tmp/Containerfile.orig"
cp "$ROOT/VERSION" "$original_version"
cp "$CONTAINERFILE" "$original_containerfile"

cleanup() {
    cp "$original_containerfile" "$CONTAINERFILE"
    cp "$original_version" "$ROOT/VERSION"
    rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
export LITMUS_PODMAN_MODE=fake
export LITMUS_PODMAN_STATEFUL_IMAGES=1
export LITMUS_PODMAN_STATE_DIR="$tmp/podman-state"
export LITMUS_PODMAN_CALLS_FILE="$tmp/podman-calls.log"
export TILLANDSIAS_BUILD_VERBOSE=0
mkdir -p "$HOME" "$(dirname "$LITMUS_PODMAN_CALLS_FILE")"
: >"$LITMUS_PODMAN_CALLS_FILE"

build_count() {
    grep -c 'podman build --format' "$LITMUS_PODMAN_CALLS_FILE" || true
}

assert_build_count() {
    local expected="$1"
    local label="$2"
    local actual
    actual="$(build_count)"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $label expected $expected podman builds, saw $actual" >&2
        cat "$LITMUS_PODMAN_CALLS_FILE" >&2
        exit 1
    fi
}

latest_hash() {
    find "$HOME" -path "*/build-hashes/.last-build-${IMAGE_NAME}.sha256" -print -quit |
        xargs cat
}

"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 1 "first source digest builds once"

"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 1 "second invocation skips"

printf '0.0.0-test-retag\n' >"$ROOT/VERSION"
"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 1 "VERSION-only change retags without build"

cp "$original_containerfile" "$CONTAINERFILE"
printf '\n# litmus-context-change\n' >>"$CONTAINERFILE"
"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 2 "context change builds once"
changed_hash="$(latest_hash)"

podman rmi "tillandsias-${IMAGE_NAME}:latest" >/dev/null
"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 2 "missing latest alias retags"

podman rmi "tillandsias-${IMAGE_NAME}:${changed_hash}" >/dev/null
"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 2 "missing canonical image retags from alias"

"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" --force >/dev/null
assert_build_count 3 "force rebuild is explicit"

echo "ok: image build convergence sequence"

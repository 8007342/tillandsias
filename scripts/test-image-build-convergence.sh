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

# This test mutates TRACKED files (VERSION and a Containerfile) because the
# behaviour under test is how build-image.sh reacts to them changing. A test
# that does that owns their restoration under EVERY exit, not just the clean one
# (order 677-33be).
#
# Live damage 2026-08-11: a pre-build litmus sweep was killed after exceeding 15
# minutes on a Windows host, leaving VERSION containing `0.0.0-test-retag`. The
# poisoned file then failed release-preflight monotonicity inside the pre-push
# hook and blocked EVERY push on that host with `blocked:version-not-monotonic`
# until a human connected the two events. The trap was `EXIT` only, and bash
# does not run an EXIT trap when the default SIGTERM disposition kills the
# shell — so the one exit path that actually occurred was the one not covered.
#
# Two layers, because neither is sufficient alone:
#   1. the trap now covers INT/TERM/HUP as well as EXIT, which handles every
#      signal that CAN be caught;
#   2. SIGKILL cannot be caught, so a STALE-SENTINEL check at start repairs a
#      previous run's damage before doing anything else. It restores from git
#      rather than from the backup copy, because a killed run's tmpdir is gone.
VERSION_TEST_SENTINEL="0.0.0-test-retag"

if [[ -f "$ROOT/VERSION" ]] && grep -qxF "$VERSION_TEST_SENTINEL" "$ROOT/VERSION"; then
    echo "notice: VERSION holds this test's sentinel from a killed run; restoring from git" >&2
    if ! git -C "$ROOT" checkout -- VERSION 2>/dev/null; then
        echo "FAIL: VERSION is poisoned with $VERSION_TEST_SENTINEL and git could not restore it" >&2
        echo "      restore it by hand before pushing; see order 677-33be" >&2
        exit 1
    fi
fi

tmp="$(mktemp -d)"
original_version="$tmp/VERSION.orig"
original_containerfile="$tmp/Containerfile.orig"
cp "$ROOT/VERSION" "$original_version"
cp "$CONTAINERFILE" "$original_containerfile"

cleanup() {
    local rc=$?
    cp "$original_containerfile" "$CONTAINERFILE"
    cp "$original_version" "$ROOT/VERSION"
    rm -rf "$tmp"
    trap - EXIT INT TERM HUP
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP

export HOME="$tmp/home"
export LITMUS_PODMAN_MODE=fake
export LITMUS_PODMAN_STATEFUL_IMAGES=1
export LITMUS_PODMAN_STATE_DIR="$tmp/podman-state"
export LITMUS_PODMAN_CALLS_FILE="$tmp/podman-calls.log"
export TILLANDSIAS_BUILD_VERBOSE=0
mkdir -p "$HOME" "$(dirname "$LITMUS_PODMAN_CALLS_FILE")"
: >"$LITMUS_PODMAN_CALLS_FILE"

# 611-kqpf: the documented command for this fixture is
#   LITMUS_PODMAN_MODE=fake scripts/test-image-build-convergence.sh proxy
# and it must be hermetic in a PLAIN shell, not only under the runner's PATH
# shim. The guard installs a fixture-owned shim (exec podman-mock.sh) when no
# recognized shim is present; the shim dir lives inside $tmp so this
# fixture's own trap removes it on every exit path.
export LITMUS_FAKE_PODMAN_BIN_DIR="$tmp/fake-podman"
# shellcheck source=scripts/test-support/litmus-fake-podman-guard.sh
source "$ROOT/scripts/test-support/litmus-fake-podman-guard.sh"

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

assert_squash_policy() {
    local line
    local token
    local squash_count
    local -a tokens
    while IFS= read -r line; do
        squash_count=0
        read -r -a tokens <<<"$line"
        for token in "${tokens[@]}"; do
            case "$token" in
                --squash) squash_count=$((squash_count + 1)) ;;
                --squash-all | --squash-all=*)
                    echo "FAIL: Containerfile build flattened an inherited shared base" >&2
                    echo "$line" >&2
                    exit 1
                    ;;
            esac
        done
        if [[ "$squash_count" -ne 1 ]]; then
            echo "FAIL: Containerfile build expected exactly one standalone --squash token, saw $squash_count" >&2
            echo "$line" >&2
            exit 1
        fi
        case " $line " in
            *" --label io.tillandsias.image.layer-policy=squash-new "*) ;;
            *)
                echo "FAIL: Containerfile build omitted the squash-new OCI label" >&2
                echo "$line" >&2
                exit 1
                ;;
        esac
    done < <(grep 'podman build --format' "$LITMUS_PODMAN_CALLS_FILE" || true)
}

latest_hash() {
    find "$HOME" -path "*/build-hashes/.last-build-${IMAGE_NAME}.sha256" -print -quit |
        xargs cat
}

"$ROOT/scripts/build-image.sh" "$IMAGE_NAME" >/dev/null
assert_build_count 1 "first source digest builds once"
assert_squash_policy

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
assert_squash_policy

echo "ok: image build convergence sequence"

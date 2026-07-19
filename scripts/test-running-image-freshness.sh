#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:user-runtime-lifecycle, spec:litmus-framework
#
# Fixture for scripts/check-running-image-freshness.sh (order 422).
#
# The gate exists to stop us debugging a defect we already fixed, because the
# RUNNING container still serves a pre-fix image. That has happened three times
# (301->302, 369->384, 414->422). A freshness gate that cannot actually DETECT
# staleness would be worse than none — it would report PASS and reinforce the
# very false-success class this repo keeps getting bitten by. So the negative
# control below is the load-bearing case: it builds a genuinely distinct image
# under the tillandsias-git repo that lacks the current content-hash tag, runs a
# container from it, and asserts the gate FAILS.
#
# Hermetic: uses a dedicated container name and image tag, and removes both on
# exit regardless of outcome.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-running-image-freshness.sh"

C_NAME="tillandsias-git-freshness-fixture"
STALE_TAG="localhost/tillandsias-git:v0.0.0-freshness-fixture"
WORK="$(mktemp -d)"

cleanup() {
    podman rm -f "$C_NAME" >/dev/null 2>&1 || true
    podman rmi -f "$STALE_TAG" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || { echo "SKIP: podman not available"; exit 0; }
[ -x "$GATE" ] || fail "gate not executable: $GATE"

if ! podman image exists localhost/tillandsias-git:latest 2>/dev/null; then
    echo "SKIP: localhost/tillandsias-git:latest not built (run ./build-git.sh first)"
    exit 0
fi

# Start from a clean slate so a leaked container from a previous run cannot
# make the negative control pass for the wrong reason.
podman rm -f "$C_NAME" >/dev/null 2>&1 || true

# --- case 1: usage errors fail loud with exit 2 ------------------------------
set +e
"$GATE" --bogus-flag >/dev/null 2>&1; RC=$?
"$GATE" nosuchimagename >/dev/null 2>&1; RC2=$?
set -e
[ "$RC" -eq 2 ] || fail "case1: unknown flag exited $RC, expected 2"
[ "$RC2" -eq 2 ] || fail "case1: unknown image exited $RC2, expected 2"
echo "case 1 ok: usage errors exit 2"

# --- case 2: nothing running is a skip, not a false failure -----------------
set +e
"$GATE" git >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 0 ] || fail "case2: no running container should exit 0, got $RC"
set +e
"$GATE" --require-running git >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "case2: --require-running with none up should exit 1, got $RC"
echo "case 2 ok: absent container skips, --require-running fails loud"

# --- case 3: NEGATIVE CONTROL — a stale running image must be detected ------
# LABEL (not RUN) so the derived image needs no write access; the image runs as
# a non-root user and any RUN touching / would fail.
printf 'FROM localhost/tillandsias-git:latest\nLABEL tillandsias.freshness.fixture="1"\n' \
    > "$WORK/Containerfile"
podman build -q -t "$STALE_TAG" "$WORK" >/dev/null 2>&1 \
    || fail "case3 setup: could not build the synthetic stale image"

STALE_ID="$(podman inspect -f '{{.Id}}' "$STALE_TAG" 2>/dev/null || true)"
CURRENT_ID="$(podman inspect -f '{{.Id}}' localhost/tillandsias-git:latest 2>/dev/null || true)"
[ -n "$STALE_ID" ] && [ "$STALE_ID" != "$CURRENT_ID" ] \
    || fail "case3 setup: synthetic image is not distinct from the current image"

podman run -d --name "$C_NAME" --entrypoint sleep "$STALE_TAG" 300 >/dev/null 2>&1 \
    || fail "case3 setup: could not start a container from the synthetic stale image"
podman ps --format '{{.Names}}' | grep -qx "$C_NAME" \
    || fail "case3 setup: synthetic stale container is not running"

set +e
OUT="$("$GATE" git 2>&1)"; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "case3: gate did not detect a stale running image (exit $RC). Output: $OUT"
printf '%s' "$OUT" | grep -q "STALE" \
    || fail "case3: gate exited 1 but did not name the staleness. Output: $OUT"
printf '%s' "$OUT" | grep -q "$C_NAME" \
    || fail "case3: gate did not name the offending container. Output: $OUT"
echo "case 3 ok: stale running image is DETECTED and named"

# --- case 4: the current image passes ---------------------------------------
podman rm -f "$C_NAME" >/dev/null 2>&1 || true
podman run -d --name "$C_NAME" --entrypoint sleep localhost/tillandsias-git:latest 300 >/dev/null 2>&1 \
    || fail "case4 setup: could not start a container from the current image"

set +e
OUT="$("$GATE" git 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] || fail "case4: current image should pass, got exit $RC. Output: $OUT"
echo "case 4 ok: current running image passes"

echo "PASS: running-image freshness gate fixture (order 422)"

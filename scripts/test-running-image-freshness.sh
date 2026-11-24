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
# A REAL stale image is one build-image.sh produced from different sources, so
# it carries a canonical 64-hex source-hash tag that simply is not the expected
# one. Modelling it with a version-style tag (as the first fixture did) tested a
# case that cannot occur, and hid the fact that a tagless image is
# INDETERMINATE rather than stale.
STALE_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
STALE_TAG="localhost/tillandsias-git:$STALE_HASH"
UNIDENTIFIED_TAG="localhost/tillandsias-git:v0.0.0-freshness-fixture"
WORK="$(mktemp -d)"

cleanup() {
    podman rm -f "$C_NAME" >/dev/null 2>&1 || true
    podman rmi -f "$STALE_TAG" >/dev/null 2>&1 || true
    podman rmi -f "$UNIDENTIFIED_TAG" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || { echo "skip:running-image-freshness:no-podman (named skip, not a pass)"; exit 0; }
[ -x "$GATE" ] || fail "gate not executable: $GATE"

if ! podman image exists localhost/tillandsias-git:latest 2>/dev/null; then
    echo "skip:running-image-freshness:no-git-image — ./build-git.sh builds it (named skip, not a pass)"
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
"$GATE" --name "$C_NAME" git >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 0 ] || fail "case2: no running container should exit 0, got $RC"
set +e
"$GATE" --require-running --name "$C_NAME" git >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "case2: --require-running with none up should exit 1, got $RC"
echo "case 2 ok: absent container skips, --require-running fails loud"

# --- case 3: NEGATIVE CONTROL — a stale running image must be detected ------
# LABEL (not RUN) so the derived image needs no write access; the image runs as
# a non-root user and any RUN touching / would fail.
# 2272-cuxh: the source-digest label is set HERE, not inherited. Only the Rust
# image_builder writes it; build-image.sh does not, so on a host whose :latest
# it built (lenovinha) there was nothing to inherit and this case died in setup.
printf 'FROM localhost/tillandsias-git:latest\nLABEL tillandsias.freshness.fixture="stale" io.tillandsias.image.source-digest="sha256:%s"\n' "$STALE_HASH" \
    > "$WORK/Containerfile"
podman build -q -t "$STALE_TAG" "$WORK" >/dev/null 2>&1 \
    || fail "case3 setup: could not build the synthetic stale image"

STALE_ID="$(podman inspect -f '{{.Id}}' "$STALE_TAG" 2>/dev/null || true)"
CURRENT_ID="$(podman inspect -f '{{.Id}}' localhost/tillandsias-git:latest 2>/dev/null || true)"
[ -n "$STALE_ID" ] && [ "$STALE_ID" != "$CURRENT_ID" ] \
    || fail "case3 setup: synthetic image is not distinct from the current image"
STALE_SOURCE_DIGEST="$(podman inspect -f '{{index .Labels "io.tillandsias.image.source-digest"}}' "$STALE_TAG" 2>/dev/null || true)"
[ -n "$STALE_SOURCE_DIGEST" ] && [ "$STALE_SOURCE_DIGEST" != "<no value>" ] \
    || fail "case3 setup: synthetic stale image did not inherit the source-digest label"

podman run -d --name "$C_NAME" --entrypoint sleep "$STALE_TAG" 300 >/dev/null 2>&1 \
    || fail "case3 setup: could not start a container from the synthetic stale image"
podman ps --format '{{.Names}}' | grep -qx "$C_NAME" \
    || fail "case3 setup: synthetic stale container is not running"

set +e
OUT="$("$GATE" --name "$C_NAME" git 2>&1)"; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "case3: gate did not detect a stale running image (exit $RC). Output: $OUT"
grep -q "STALE" <<<"$OUT" \
    || fail "case3: gate exited 1 but did not name the staleness. Output: $OUT"
grep -q "$C_NAME" <<<"$OUT" \
    || fail "case3: gate did not name the offending container. Output: $OUT"
echo "case 3 ok: stale running image is DETECTED and named"

# --- case 4: the current image passes ---------------------------------------
# 2272-cuxh: only where :latest IS this checkout's image. Elsewhere a stale
# :latest (any branch that edits images/git/) read as a red gate, and one with
# no hash tag passed as indeterminate, so "current" was never asked.
EXPECTED="$("$ROOT/scripts/hash-image-sources.sh" git "$ROOT/images/git" "$ROOT")" || fail "case4 setup: cannot hash images/git"
LATEST_TAGS="$(podman inspect -f '{{range .RepoTags}}{{.}} {{end}}' localhost/tillandsias-git:latest 2>/dev/null || true)"
if [[ " $LATEST_TAGS " != *" localhost/tillandsias-git:$EXPECTED "* ]]; then
    echo "not-run:running-image-freshness:case4 — :latest is not this checkout's image (${EXPECTED:0:12}); ./build-git.sh builds it"
else
    podman rm -f "$C_NAME" >/dev/null 2>&1 || true
    podman run -d --name "$C_NAME" --entrypoint sleep localhost/tillandsias-git:latest 300 >/dev/null 2>&1 \
        || fail "case4 setup: could not start a container from the current image"
    set +e
    OUT="$("$GATE" --name "$C_NAME" git 2>&1)"; RC=$?
    set -e
    [ "$RC" -eq 0 ] || fail "case4: current image should pass, got exit $RC. Output: $OUT"
    [[ "$OUT" == *"ok: $C_NAME runs current"* ]] || fail "case4: the gate exited 0 without saying current. Output: $OUT"
    echo "case 4 ok: current running image passes"
fi

# --- case 5: label-only identity is INDETERMINATE, never stale ---------------
# Tag absence does not imply stale content: build-image.sh prunes tags on later
# builds, and the Rust image_builder identifies images by a source-digest LABEL
# that shell cannot recompute. Claiming STALE here would be asserting more than
# the evidence supports — the same error as claiming PASS on ambiguous
# evidence, just in the safer direction.
podman rm -f "$C_NAME" >/dev/null 2>&1 || true
printf 'FROM localhost/tillandsias-git:latest\nLABEL tillandsias.freshness.fixture="unidentified" io.tillandsias.image.source-digest="sha256:%s"\n' "$STALE_HASH" \
    > "$WORK/Containerfile"
podman build -q -t "$UNIDENTIFIED_TAG" "$WORK" >/dev/null 2>&1 \
    || fail "case5 setup: could not build the unidentified image"
podman inspect -f '{{range .RepoTags}}{{.}} {{end}}' "$UNIDENTIFIED_TAG" 2>/dev/null \
    | grep -qE 'tillandsias-git:[0-9a-f]{64}' \
    && fail "case5 setup: the unidentified image unexpectedly carries a canonical hash tag"
UNIDENTIFIED_SOURCE_DIGEST="$(podman inspect -f '{{index .Labels "io.tillandsias.image.source-digest"}}' "$UNIDENTIFIED_TAG" 2>/dev/null || true)"
[ -n "$UNIDENTIFIED_SOURCE_DIGEST" ] && [ "$UNIDENTIFIED_SOURCE_DIGEST" != "<no value>" ] \
    || fail "case5 setup: unidentified image did not inherit the source-digest label"
podman run -d --name "$C_NAME" --entrypoint sleep "$UNIDENTIFIED_TAG" 300 >/dev/null 2>&1 \
    || fail "case5 setup: could not start the unidentified container"

set +e
OUT="$("$GATE" --name "$C_NAME" git 2>&1)"; RC=$?
set -e
[ "$RC" -eq 0 ] || fail "case5: an unidentifiable image must not be reported as drift (exit $RC). Output: $OUT"
grep -qi "indeterminate" <<<"$OUT" \
    || fail "case5: expected an indeterminate verdict. Output: $OUT"
grep -q "STALE" <<<"$OUT" \
    && fail "case5: must NOT claim STALE without positive evidence. Output: $OUT"
echo "case 5 ok: unidentifiable image is INDETERMINATE, not stale"

# --- case 6: --strict turns indeterminate into a failure --------------------
set +e
"$GATE" --strict --name "$C_NAME" git >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 3 ] || fail "case6: --strict must exit 3 on indeterminate, got $RC"
echo "case 6 ok: --strict escalates indeterminate to exit 3"

echo "PASS: running-image freshness gate fixture (order 422)"

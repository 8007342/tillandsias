#!/usr/bin/env bash
# check-nix-builder-e2e.sh — validate the nix cache + crane build end-to-end
#
# Runs a full `nix build .#tillandsias-x86_64-musl` inside the builder
# container with the enclave cache as the sole substituter, measures the build,
# and validates that the 96s shape reproduces (within tolerance).
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-e2e:<wall=<s>>:substituted=<n>:built=<n>:total=<n>
#   ok:nix-e2e:skip:cache-unreachable
#   ok:nix-e2e:skip:no-nix
#   blocked:nix-e2e:<build-failed|timeout|image-failed>
#
# Exit 0 on ok/skip, 1 on blocked.
#
# USAGE
#   scripts/check-nix-builder-e2e.sh              # full validation
#   scripts/check-nix-builder-e2e.sh --dry-run    # check prereqs only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
NIX_CACHE_SCRIPT="${TILLANDSIAS_NIX_CACHE_SCRIPT:-$SCRIPT_DIR/nix-cache-service.sh}"
IMAGE_NAME="${TILLANDSIAS_NIX_BUILDER_IMAGE:-tillandsias-nix-builder}"
CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Expected wall clock for a warm-cache build (seconds). The 96s measurement
# was on macuahuitl (RTX A5000, 20 cores). Allow 3x tolerance for different
# hardware.
EXPECTED_WALL=96
TOLERANCE_FACTOR=3

have_nix() { command -v nix >/dev/null 2>&1; }
store_present() { [ -d "$CHROOT_STORE/nix/store" ]; }

cache_reachable() {
    [[ -x "$NIX_CACHE_SCRIPT" ]] || return 1
    local status
    status="$("$NIX_CACHE_SCRIPT" status 2>/dev/null)" || return 1
    [[ "$status" == *"running"* ]]
}

image_exists() {
    podman image exists "$IMAGE_NAME" 2>/dev/null
}

# ── Prereqs ───────────────────────────────────────────────────────────────
have_nix || { echo "ok:nix-e2e:skip:no-nix"; exit 0; }
cache_reachable || { echo "ok:nix-e2e:skip:cache-unreachable"; exit 0; }

if [[ "$DRY_RUN" == 1 ]]; then
    echo "ok:nix-e2e:dry-run:prereqs-met"
    exit 0
fi

# ── Ensure the builder image exists ───────────────────────────────────────
if ! image_exists; then
    local containerfile="$REPO_ROOT/nix/builder/Containerfile"
    if [[ ! -f "$containerfile" ]]; then
        echo "blocked:nix-e2e:image-failed:Containerfile not found" >&2
        exit 1
    fi
    echo "[nix-e2e] Building builder image..." >&2
    podman build -t "$IMAGE_NAME" -f "$containerfile" "$(dirname "$containerfile")" \
        2>&1 | while IFS= read -r line; do printf '  [build] %s\n' "$line" >&2; done || {
        echo "blocked:nix-e2e:image-failed" >&2
        exit 1
    }
fi

# ── Get substituter args ──────────────────────────────────────────────────
SUB_ARGS=""
if [[ -x "$NIX_CACHE_SCRIPT" ]]; then
    SUB_ARGS="$("$NIX_CACHE_SCRIPT" substituter-args 2>/dev/null || true)"
fi

# ── Build nix command with store and substituter flags ────────────────────
NIX_CMD="nix --extra-experimental-features 'nix-command flakes' --store /host-store"
if [[ -n "$SUB_ARGS" ]]; then
    # Parse multi-line substituter args into space-separated flags
    NIX_CMD="$NIX_CMD $(echo "$SUB_ARGS" | tr '\n' ' ')"
fi

# ── Run the build inside the builder container ────────────────────────────
echo "[nix-e2e] Running nix build inside builder container..." >&2

START_WALL=$(date +%s)

# The container mounts the persistent store, source tree, and TLS CA.
# We use --timeout to prevent hangs.
BUILD_OUTPUT=$(podman run --rm \
    --privileged \
    --network host \
    --security-opt label=disable \
    -v "$CHROOT_STORE:/host-store" \
    -v "$REPO_ROOT:/work" \
    -v "$CA_DIR:/tmp/tillandsias-ca:ro" \
    -e "container=podman" \
    "$IMAGE_NAME" \
    -c "cd /work && $NIX_CMD build .#tillandsias-x86_64-musl --print-build-logs 2>&1" \
    2>&1) || {
        END_WALL=$(date +%s)
        ELAPSED=$((END_WALL - START_WALL))
        echo "blocked:nix-e2e:build-failed:wall=${ELAPSED}s" >&2
        echo "$BUILD_OUTPUT" | tail -20 >&2
        exit 1
    }

END_WALL=$(date +%s)
ELAPSED=$((END_WALL - START_WALL))

# ── Parse build output for metrics ────────────────────────────────────────
# nix build --print-build-logs outputs lines like:
#   copying 563 paths from the binary cache...
#   building '/nix/store/...-tillandsias.drv'...
SUBSTITUTED=$(echo "$BUILD_OUTPUT" | grep -c '^copying.*paths from the binary cache' || echo 0)
BUILT=$(echo "$BUILD_OUTPUT" | grep -c '^building' || echo 0)
TOTAL=$((SUBSTITUTED + BUILT))

# ── Validate the 96s shape ────────────────────────────────────────────────
MAX_WALL=$((EXPECTED_WALL * TOLERANCE_FACTOR))

if [[ "$ELAPSED" -gt "$MAX_WALL" ]]; then
    echo "blocked:nix-e2e:timeout:wall=${ELAPSED}s:expected=${EXPECTED_WALL}s:max=${MAX_WALL}s" >&2
    echo "$BUILD_OUTPUT" | tail -5 >&2
    exit 1
fi

# ── Record metrics ────────────────────────────────────────────────────────
METRICS_DIR="$REPO_ROOT/.cache/metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || true
METRICS_FILE="$METRICS_DIR/nix-e2e-$(date +%Y%m%d).jsonl"
cat >> "$METRICS_FILE" <<EOF
{"ts":"$(date -Iseconds)","wall_s":$ELAPSED,"substituted":$SUBSTITUTED,"built":$BUILT,"total":$TOTAL,"host":"$(hostname)"}
EOF

echo "ok:nix-e2e:wall=${ELAPSED}s:substituted=${SUBSTITUTED}:built=${BUILT}:total=${TOTAL}"
exit 0

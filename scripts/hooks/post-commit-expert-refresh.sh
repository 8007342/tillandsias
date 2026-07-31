#!/usr/bin/env bash
# post-commit-expert-refresh.sh — Incremental expert refresh on commit (order 396)
# @trace packet:experts-refresh-on-commit
#
# Detects which files changed and triggers async refresh so 'what changed'
# questions answer against the current tree, not launch state.
#
# Refresh strategy (per 393 research):
#   - L0 (plan/, methodology/): engine reads files fresh at query time —
#     answers reflect the working tree instantly. No index to refresh.
#   - crates/tillandsias-plan/: triggers async binary rebuild (bounded).
#   - L1 prose indexes (future): re-indexes changed corpora here.
#
# NEVER blocks the commit. Forks background work immediately and exits.
# LOUD on failure (writes to TILLANDSIAS_HOOK_LOG with clear marker).
#
# Budget: hook fork + changed-file detection < 50 ms.
#         Background work contributes zero latency to commit/push.
#         Measured and pinned at the bottom of this file.

set -uo pipefail

HOOK_NAME="post-commit-expert-refresh"
HOOK_START=$(date +%s%N 2>/dev/null || echo 0)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$REPO_ROOT/plan/index.yaml" ] || exit 0

CHANGED=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null) || exit 0
[ -n "$CHANGED" ] || exit 0

HOOK_LOG="${TILLANDSIAS_HOOK_LOG:-/tmp/tillandsias-hooks.log}"

# ── L0: plan/ and methodology/ ──────────────────────────────────────
# The engine reads these files fresh at query time (tillandsias-plan
# reads plan/index.yaml + methodology/**/*.yaml on every invocation).
# No index to refresh — answers reflect the working tree instantly.
# When L1 prose indexes are added, re-index changed corpora here:
#
#   l1_files=$(echo "$CHANGED" | grep -E '^plan/|^methodology/' || true)
#   if [ -n "$l1_files" ]; then
#       (re-index-corpora "$l1_files") &
#   fi

# ── Crate changes → async binary rebuild ────────────────────────────
# The tillandsias-plan binary changes when its crate sources change.
# Trigger a background, bounded rebuild so the next answer uses the
# new code without waiting for the next forge launch.
if echo "$CHANGED" | grep -qE '^crates/tillandsias-plan/'; then
    (
        BIN_DIR="${FORGE_EXPERTS_BIN_DIR:-$HOME/.local/bin}"
        mkdir -p "$BIN_DIR" 2>/dev/null || true
        BIN_PATH="$BIN_DIR/tillandsias-plan"

        # Bounded rebuild: 600s default (matches FORGE_EXPERTS_BUILD_TIMEOUT)
        BUILD_TIMEOUT="${FORGE_EXPERTS_BUILD_TIMEOUT:-600}"

        # Resolve target directory from CARGO_TARGET_DIR or default repository target/
        if [ -n "${CARGO_TARGET_DIR:-}" ]; then
            if [[ "$CARGO_TARGET_DIR" = /* ]]; then
                TARGET_DIR="$CARGO_TARGET_DIR"
            else
                TARGET_DIR="$REPO_ROOT/$CARGO_TARGET_DIR"
            fi
        else
            TARGET_DIR="$REPO_ROOT/target"
        fi
        BUILT_BIN="$TARGET_DIR/release/tillandsias-plan"

        if command -v cargo &>/dev/null; then
            if timeout "$BUILD_TIMEOUT" cargo build --release -p tillandsias-plan >> "$HOOK_LOG" 2>&1; then
                if [ -f "$BUILT_BIN" ] && [ -r "$BUILT_BIN" ]; then
                    mkdir -p "$BIN_DIR" 2>/dev/null
                    if cp "$BUILT_BIN" "$BIN_PATH" 2>/dev/null; then
                        echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) binary rebuilt from commit $(git rev-parse --short HEAD 2>/dev/null)" >> "$HOOK_LOG"
                    else
                        echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: binary install failed (cp to $BIN_PATH failed)" >> "$HOOK_LOG"
                    fi
                else
                    echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: binary install failed (built artifact $BUILT_BIN missing or unreadable)" >> "$HOOK_LOG"
                fi
            else
                echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: binary rebuild exited $? (timeout=${BUILD_TIMEOUT}s)" >> "$HOOK_LOG"
            fi
        else
            echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: cargo not available — binary rebuild deferred" >> "$HOOK_LOG"
        fi
    ) &
    disown -a 2>/dev/null || true
fi

# ── Measure and pin latency budget ──────────────────────────────────
# The hook itself must add NO perceptible latency to commit/push.
# Only the fork + changed-file detection runs synchronously.
HOOK_END=$(date +%s%N 2>/dev/null || echo 0)
if [ "$HOOK_START" -ne 0 ] && [ "$HOOK_END" -ne 0 ]; then
    HOOK_LATENCY_MS=$(( (HOOK_END - HOOK_START) / 1000000 ))
    echo "[$HOOK_NAME] latency=${HOOK_LATENCY_MS}ms budget_commit=<50ms budget_total=<50ms" >> "$HOOK_LOG" 2>/dev/null || true
fi

exit 0

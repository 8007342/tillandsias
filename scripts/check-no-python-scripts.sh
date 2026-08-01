#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

cargo build --quiet -p tillandsias-policy
POLICY_BIN="target/debug/tillandsias-policy"
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    if [[ "$CARGO_TARGET_DIR" = /* ]]; then
        [[ -x "$CARGO_TARGET_DIR/debug/tillandsias-policy" ]] && POLICY_BIN="$CARGO_TARGET_DIR/debug/tillandsias-policy"
    else
        [[ -x "$ROOT/$CARGO_TARGET_DIR/debug/tillandsias-policy" ]] && POLICY_BIN="$ROOT/$CARGO_TARGET_DIR/debug/tillandsias-policy"
    fi
fi
exec "$POLICY_BIN" check-no-python-scripts

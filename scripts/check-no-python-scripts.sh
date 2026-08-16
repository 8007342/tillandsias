#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

cargo build --quiet -p tillandsias-policy
# Run-don't-stat (order 770-ifeg): on a shared Windows/WSL checkout the
# extensionless target/ path can hold the OTHER platform's artifact, and an
# existence check execs it into "Exec format error". Probe by execution.
. "$ROOT/scripts/plan-binary-probe.sh"
if ! POLICY_BIN="$(resolve_target_binary tillandsias-policy debug "$ROOT")"; then
    echo "refused:no-runnable-tillandsias-policy (probed target/debug and CARGO_TARGET_DIR by execution)" >&2
    exit 1
fi
exec "$POLICY_BIN" check-no-python-scripts

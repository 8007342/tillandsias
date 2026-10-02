#!/usr/bin/env bash
# Retroactive parity harness: baseline Bash comes only from BASE, never production.
set -euo pipefail
BASE=8c7af38867886b7144a0c27a33eec2de4451ba46
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary)"
W="${TMPDIR:-/tmp}/opencode/1533-ew3n-parity-$$"; mkdir -p "$W/legacy/scripts" "$W/out"
trap 'rm -rf "$W"' EXIT
for n in check-guest-unit-hardening check-tray-refresh-no-polling check-podman-sync-budgets; do
  git -C "$ROOT" show "$BASE:scripts/$n.sh" >"$W/legacy/scripts/$n.sh"; chmod +x "$W/legacy/scripts/$n.sh"
done
# The full named-arm corpus is intentionally constructed from the fixture source
# mutations; every result is written as raw stdout/stderr bytes and its rc.
# See raw.json for the executable/environment identities used by the receipt.

#!/usr/bin/env bash
# Stub (order 1443-sb9b): the logic is scripts/lua/pre-push-main-branch-affordance.lua, run by the
# sandboxed `tillandsias-plan lua` and reading the discipline seed. The sandbox has no os.exit, so
# the verdict line IS the result: exit 0 only on exactly ok:main-branch-affordance. FAILS CLOSED.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ] || ! "$PLAN" capabilities >/dev/null 2>&1; then
    echo "blocked:main-branch-affordance:no-plan-binary"; echo "  no runnable tillandsias-plan (${PLAN:-none}); remedy: cargo build --release -p tillandsias-plan" >&2; command -v cargo >/dev/null 2>&1 || echo "  no cargo on this host (1255-s4im): toolbox run --container tillandsias-builder cargo build --release -p tillandsias-plan — or hand the work off ungated: scripts/salvage-dirty-worktree.sh <slug>" >&2; exit 1
fi
verdict="$("$PLAN" lua "$ROOT/scripts/lua/pre-push-main-branch-affordance.lua" "$PLAN" "${TILLANDSIAS_HOST_KIND:-}" "${OS:-}")"
printf '%s\n' "${verdict:-blocked:main-branch-affordance:no-verdict}"
[ "$verdict" = "ok:main-branch-affordance" ]

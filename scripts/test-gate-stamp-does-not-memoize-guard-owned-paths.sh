#!/usr/bin/env bash
# @trace order:1127-waxf, order:930-i6x4, order:1036-e5w9
#
# test-gate-stamp-does-not-memoize-guard-owned-paths.sh — pin that the gate memo
# can tell "nothing moved" from "only the plan ledger moved", so a plan-only
# commit can no longer memoize away the guards written for plan-only commits.
#
# THE DEFECT. `compute` deliberately excludes plan/index.d/*.yaml,
# plan/loop_status.d/*.md and plan/mo-full-attestations.d/*.md (930-i6x4 — a
# sound optimisation: without it every sibling landing staled a stamp that
# remained true of every byte of code). Its side effect is that those are
# EXACTLY the paths check-fragment-status-loss.sh and
# `tillandsias-plan check --strict-fragments` exist to read. The exclusion and
# the guards cover the same paths in opposite directions and nothing reconciled
# them, so a commit touching only them could not stale the stamp, the memo
# returned ok:gate-fresh, and the guards never ran.
#
# MEASURED on lenovinha 2026-09-12, before the fix, on the real checkout:
#     (plant a 'completed' event on a packet that folds 'ready')
#     scripts/check-fragment-status-loss.sh -> rc=1, violation:fragment-status-loss:1
#     ./build.sh --check                    -> rc=0 in 2026ms, ok:gate-fresh,
#                                              guard appears 0 times in the log
#   after the fix, same tree:
#     ./build.sh --check                    -> rc=1 in 3310ms, naming the violation
#   and the 930-i6x4 cost control, a CLEAN fragment:
#     ./build.sh --check                    -> rc=0 in 4323ms (guards ran; no full gate)
#
# WHAT THIS FIXTURE COVERS AND WHAT IT DOES NOT, stated rather than implied.
# It drives scripts/gate-stamp.sh directly — the memo DECISION, which is where
# the defect lived. It does NOT invoke ./build.sh: this fixture runs INSIDE
# ./build.sh --check, and a nested gate would clobber the outer run's stamp and
# recurse. The end-to-end numbers above were measured by hand and are recorded
# on the 1127-waxf row; the wiring between the verdict and the guards is pinned
# by arm 5 below, which is a structural assertion rather than an execution.
#
# Hermetic: scratch git repo, no network. Removed on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMPER="$ROOT/scripts/gate-stamp.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/gate-stamp-plan.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
G() { git -C "$W/wc" -c user.email=t@t -c user.name=t "$@"; }

git init -q -b linux-next "$W/wc"
mkdir -p "$W/wc/scripts" "$W/wc/plan/index.d" "$W/wc/plan/loop_status.d"
cp "$STAMPER" "$W/wc/scripts/gate-stamp.sh"
printf 'code\n' > "$W/wc/scripts/some-code.sh"
printf 'packets: []\n' > "$W/wc/plan/index.yaml"
G add -A >/dev/null 2>&1; G commit -q -m base

S() { ( cd "$W/wc" && bash scripts/gate-stamp.sh "$@" ); }
STAMP_FILE="$W/wc/.git/tillandsias-gate-stamp"

# Write stamps through gate-stamp.sh's OWN write path rather than by hand.
# GATE_STAMP_REQUIRE_TOKEN=0 is the documented bypass for the 940-f77j pass
# token, and using the real writer means the toolchain field is whatever this
# host actually reports — a hand-written one would differ and every arm below
# would die on stale:toolchain-changed for a reason unrelated to this packet.
_stamp_now() { ( cd "$W/wc" && GATE_STAMP_REQUIRE_TOKEN=0 bash scripts/gate-stamp.sh write --dispatch check >/dev/null ); }

D0="$(S compute)"
P0="$(S plan-digest)"

# ── ARM 1: the two digests are INDEPENDENT ──────────────────────────────────
# This is the property the whole fix rests on, and it is the one that could
# silently regress if someone ever "tidies" the 930-i6x4 exclusion.
printf 'packets: []\n' > "$W/wc/plan/index.d/20260912t000000z-probe.yaml"
D1="$(S compute)"; P1="$(S plan-digest)"
if [ "$D0" = "$D1" ]; then
    ok "arm1: adding a plan/index.d fragment does NOT move the code digest (930-i6x4 intact)"
else
    bad "arm1: the code digest moved on a plan fragment — 930-i6x4's exclusion is gone, and every sibling landing will re-gate"
fi
if [ "$P0" != "$P1" ]; then
    ok "arm1: the plan digest DOES move on that same fragment"
else
    bad "arm1: the plan digest did not move — the memo cannot see the ledger at all"
fi

# ── ARM 2: nothing moved -> full memo ───────────────────────────────────────
rm -f "$W/wc/plan/index.d/20260912t000000z-probe.yaml"
_stamp_now
out="$(S memo-check check)"
if [ "${out%% *}" = "ok:gate-fresh" ]; then
    ok "arm2: with both digests matching the memo is still whole-gate fresh (cost path unchanged)"
else
    bad "arm2: expected ok:gate-fresh, got: $out"
fi

# ── ARM 3: only the ledger moved -> the THIRD verdict ────────────────────────
printf 'packets: []\n' > "$W/wc/plan/index.d/20260912t000001z-moved.yaml"
out="$(S memo-check check)"
if [ "${out%% *}" = "ok:gate-fresh-except-plan" ]; then
    ok "arm3: a plan-only change yields ok:gate-fresh-except-plan, not ok:gate-fresh"
else
    bad "arm3: a plan-only change did not produce the partial verdict, got: $out"
fi
# NOT stale: refusing outright would re-impose the cost 930-i6x4 removed, and a
# gate that costs a full run per fragment is the one that gets worked around.
if [ "${out%% *}" = "stale:tree-changed-since-gate" ]; then
    bad "arm3: the memo refused outright — correct about the hole, wrong about the cost (930-i6x4)"
fi

# ── ARM 4: a stamp with no plan_digest FAILS CLOSED ─────────────────────────
_stamp_now
# Strip the field to synthesise a stamp written before this order.
LC_ALL=C sed -i '/^plan_digest /d' "$STAMP_FILE"
out="$(S memo-check check)"
if [ "$out" = "stale:no-plan-digest-recorded" ]; then
    ok "arm4: a pre-1127 stamp is stale, not assumed-unchanged (fail closed, one re-gate per host)"
else
    bad "arm4: a stamp with no plan_digest should be stale, got: $out"
fi

# ── ARM 5: the verdict is WIRED to the guards in build.sh ───────────────────
# Structural, and labelled as such: this fixture cannot run ./build.sh (it runs
# inside it). What it can refuse is the verdict existing with nothing hanging
# off it — a memo arm that returns the partial verdict and then skips the guards
# anyway would reproduce the defect with extra steps.
_arm="$(awk '/"ok:gate-fresh-except-plan "\*\)/,/;;/' "$ROOT/build.sh")"
if [ -z "$_arm" ]; then
    bad "arm5: build.sh has no ok:gate-fresh-except-plan arm — the verdict goes nowhere"
elif grep -q 'check-fragment-status-loss.sh' <<<"$_arm" && grep -q 'strict-fragments' <<<"$_arm"; then
    ok "arm5: build.sh's partial-memo arm runs BOTH ledger guards"
else
    bad "arm5: build.sh's partial-memo arm does not run both ledger guards"
fi

echo "test-gate-stamp-does-not-memoize-guard-owned-paths: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]

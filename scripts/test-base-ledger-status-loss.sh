#!/usr/bin/env bash
# @trace order:751-i9mb, spec:methodology-accountability
#
# Fixture for scripts/check-base-ledger-status-loss.sh (order 751-i9mb).
#
# The checker exists because a completion recorded INLINE in the base ledger was
# invisible to the fragment-only detector, so packet 532 sat claimable with its
# exit criterion already green while `./build.sh --check` printed
# `ok:no-fragment-status-loss:16 checked`.
#
# A checker for that which cannot itself be seen to fail would be the same
# failure one level up, so every verdict is proven reachable here on a
# throwaway tree — including the two negative controls the packet demands, which
# are the ones that keep this from degrading into "flag everything".

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-base-ledger-status-loss.sh"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$CHECK" ] || fail "checker not found: $CHECK"

# Resolve the binary the same way the checker does, and SKIP loudly rather than
# inventing a pass if it is absent (702-68zj).
# shellcheck source=/dev/null
. "$PROBE"
PLAN="$(resolve_plan_binary)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "SKIP: tillandsias-plan not built; cannot exercise the fold"
    exit 0
fi

mkdir -p "$WORK/scripts" "$WORK/target/release" "$WORK/plan/index.d"
cp "$CHECK" "$PROBE" "$WORK/scripts/"
cp "$PLAN" "$WORK/target/release/tillandsias-plan"

# Build a base ledger. `status_arg` is the packet's status; `events_arg` is the
# events block, indented to sit under the packet.
#
# The shape mirrors the REAL base: packets live at plan_index.steps[], NOT at a
# top-level `packets:` key. That distinction is the entire defect — the
# subcommand walked `doc["packets"]` and therefore parsed the whole base ledger
# and printed nothing, with exit 0, which is indistinguishable from "declares no
# terminal events".
write_base() {
    _status="$1"; _events="$2"
    {
        printf 'plan_index:\n  version: v1\n  root: plan/\n  steps:\n'
        printf '    - packet_id: inference-state-warm-grammar-multimodel\n'
        printf '      order: 532\n'
        printf '      title: "inference state warm grammar multimodel"\n'
        printf '      status: %s\n' "$_status"
        printf '      kind: fix\n'
        printf '      depends_on: []\n'
        printf '%s' "$_events"
    } > "$WORK/plan/index.yaml"
}

CLOSURE_EVENTS=$(cat <<'YAML'
      events:
        - type: completed
          ts: "2026-08-15T02:01:51Z"
          host: fixture
          summary: |
            litmus:inference-model-preload-policy STEP 15 committed and passing
        - type: claim
          ts: "2026-08-15T02:06:00Z"
          host: fixture
          summary: |
            claimed AFTER the closure — this is what left the status non-terminal
YAML
)
NONCLOSURE_EVENTS=$(cat <<'YAML'
      events:
        - type: progress
          ts: "2026-08-15T02:01:51Z"
          host: fixture
          summary: |
            progress is not a closure
        - type: claim
          ts: "2026-08-15T02:06:00Z"
          host: fixture
          summary: |
            a claim is not a closure either
YAML
)
FALSIFIED_EVENTS=$(cat <<'YAML'
      events:
        - type: completed
          ts: "2026-08-15T02:01:51Z"
          host: fixture
          summary: |
            a closure that was later withdrawn
        - type: falsified
          ts: "2026-08-15T05:00:00Z"
          host: fixture
          summary: |
            the closure above was wrong and is retracted
YAML
)

run() { (cd "$WORK" && bash scripts/check-base-ledger-status-loss.sh 2>/dev/null); }
run_err() { (cd "$WORK" && bash scripts/check-base-ledger-status-loss.sh 2>&1 >/dev/null); }
rc_of() { (cd "$WORK" && bash scripts/check-base-ledger-status-loss.sh >/dev/null 2>&1); echo $?; }

# --- case 1: THE DEFECT. A closure event in the BASE beside a non-terminal
# status is REPORTED. This is the 532 shape verbatim: two closure events, then a
# claim event that postdates them and leaves the status behind.
write_base "in_progress" "$CLOSURE_EVENTS"
out="$(run)"
[ "$out" = "advisory:base-status-loss:1" ] \
    || fail "case 1: a base-ledger closure beside a non-terminal status must be reported, got '$out'"
err="$(run_err)"
case "$err" in
    *inference-state-warm-grammar-multimodel*folds\ as\ \'in_progress\'*) ;;
    *) fail "case 1: the advisory must NAME the packet and its folded status, got '$err'" ;;
esac
echo "ok: case 1 — a completion recorded in the base is no longer invisible"

# --- case 2: THE SAME LEDGER WITH THE STATUS CORRECTED IS SILENT ------------
# Exit criterion 2's second half. Without this the checker could pass case 1 by
# reporting every packet that carries a closure event at all, which on the real
# base is 95 of them — noise within one run, ignored by the next.
write_base "completed" "$CLOSURE_EVENTS"
out="$(run)"
[ "$out" = "ok:no-base-status-loss:1 checked" ] \
    || fail "case 2: a correctly-closed packet must NOT be reported, got '$out'"
echo "ok: case 2 — correcting the status silences it (so this is not a blanket flag)"

# --- case 3 (NEGATIVE CONTROL): progress/claim/note are NOT closures ---------
# A packet legitimately in_progress must stay quiet, or every actively-claimed
# packet in the fleet is flagged on every build.
write_base "in_progress" "$NONCLOSURE_EVENTS"
out="$(run)"
[ "$out" = "ok:no-base-status-loss:0 checked" ] \
    || fail "case 3: progress/claim events must not read as a closure, got '$out'"
echo "ok: case 3 — a legitimately in_progress packet is not flagged"

# --- case 4 (NEGATIVE CONTROL): a FALSIFIED closure is not a closure ---------
# The packet names this one explicitly. `falsified` is the one event that moves
# a packet DOWN the closure ladder (closure_rank), so a withdrawn completion
# must not keep reporting forever.
write_base "in_progress" "$FALSIFIED_EVENTS"
out="$(run)"
case "$out" in
    "ok:no-base-status-loss:0 checked") ;;
    "advisory:base-status-loss:1")
        fail "case 4: a FALSIFIED closure must not be reported as a live one (got '$out') — see closure_rank in crates/tillandsias-plan/src/lib.rs" ;;
    *) fail "case 4: unexpected verdict '$out'" ;;
esac
echo "ok: case 4 — a withdrawn closure does not keep reporting"

# --- case 5: ADVISORY, NEVER A GATE -----------------------------------------
# Exit criterion 4. If this ever returns non-zero it becomes a build gate by
# accident, and the first false positive on a historical row gets the whole
# thing switched off.
write_base "in_progress" "$CLOSURE_EVENTS"
rc="$(rc_of)"
[ "$rc" = "0" ] \
    || fail "case 5: the checker must exit 0 even when reporting (advisory, not a gate), got rc=$rc"
echo "ok: case 5 — reporting does not fail the build"

# --- case 6: AN UNPARSEABLE BASE IS NOT 'ok' --------------------------------
# ORDER 787-f7dh. Silence from a parser is not evidence of absence. If this said
# `ok:`, a ledger nobody could read would report as clean — which is the exact
# failure this whole file exists to close, one level up.
printf 'plan_index:\n  steps:\n    - packet_id: broken\n      summary: ": "\n     bad_indent: true\n' \
    > "$WORK/plan/index.yaml"
out="$(run)"
case "$out" in
    skip:base-ledger-unparseable|ok:no-base-status-loss:0\ checked)
        [ "$out" = "skip:base-ledger-unparseable" ] \
            || fail "case 6: an unparseable base must NOT read as ok, got '$out'" ;;
    *) fail "case 6: unexpected verdict '$out'" ;;
esac
echo "ok: case 6 — an unexamined ledger is never reported as clean"

# --- case 7: no base ledger at all -------------------------------------------
rm -f "$WORK/plan/index.yaml"
out="$(run)"
[ "$out" = "skip:no-base-ledger" ] \
    || fail "case 7: a missing base must skip, got '$out'"
echo "ok: case 7 — nothing to check is said out loud too"

echo "PASS: base-ledger status-loss fixture 7/7 scenarios green (defect-reported, corrected-silent, progress-not-closure, falsified-not-closure, advisory-not-gate, unparseable-not-ok, no-base-skips)"
echo "ok:base-status-loss-fixture:7"
exit 0

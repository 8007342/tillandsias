#!/usr/bin/env bash
# ORDER 1085-g52w. A sanctioned reopen must land; an unapplied closure must not.
#
# `set-field --reopen-evidence` (650-dq6u) is the prescribed way to reopen a
# terminally-closed packet, and it necessarily leaves a terminal EVENT beside a
# non-terminal fold. check-fragment-status-loss refused exactly that shape, so
# NO HOST COULD LAND A REOPEN: the choices were to abandon the correction or to
# push red, and abandoning silently converts a falsified closure back into a
# standing one. Measured on yoga 2026-09-05 reopening 1033-iycs.
#
# THE DISCRIMINATOR IS TIME. A terminal event OLDER than the winning status
# transition is HISTORY. One NEWER than it, or with no transition at all, is the
# loss the guard exists to catch.
#
# ARM 2 IS WHY THIS FIXTURE EXISTS. Arms 1 and 3 alone would both score green
# against a guard that had simply been DELETED. Arm 2 is the negative control:
# it fails if the fix widened the accepted-status set instead of comparing
# timestamps, which the order names as the attractive wrong turn (accepting
# in_progress against a completed event deletes the real subject of the guard —
# 11 of 21 such packets on 2026-08-09).
#
# REGIME. Each arm builds a COMPLETE scratch ledger (base + fragments) and runs
# the REAL guard inside it; the guard resolves its root from its own location,
# so it is copied in rather than pointed at. Nothing reads the live ledger, so no
# arm can pass or fail because of what the fleet is holding. Timestamps are fixed
# literals inside the scratch ledger, which is the one place an absolute moment
# is correct: these arms are about ORDERING between two stamps, and drawing them
# from the clock would make the ordering incidental.
#
# EVERY ARM CHECKS ITS PRECONDITION FIRST, and that is not ceremony. The first
# cut of this fixture wrote a status walk-back with no falsified event; the fold
# REFUSED it (650-dq6u: the only path down the closure ladder is a falsified
# event), the packet stayed `completed`, and the guard passed for a reason that
# had nothing to do with the fix. A green arm over a ledger that does not hold
# the shape under test is worth less than no arm at all.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

# ABSOLUTE, because every arm runs the guard after a `cd` into a scratch tree.
# resolve_plan_binary answers RELATIVE to the repo root (target/debug/...), and a
# relative path evaluated from somewhere else silently resolves to nothing: the
# first run of this fixture reported an empty folded status for all three arms
# for exactly that reason. The preconditions caught it, which is what they are
# for, but the binary has to be pinned here.
PLAN_BIN="$(. "$ROOT/scripts/plan-binary-probe.sh" && resolve_plan_binary 2>/dev/null || printf '')"
case "$PLAN_BIN" in
    "") ;;
    /*) ;;
    *)  PLAN_BIN="$ROOT/$PLAN_BIN" ;;
esac
[ -x "$PLAN_BIN" ] || PLAN_BIN=""
if [ -z "$PLAN_BIN" ]; then
    bad "no runnable tillandsias-plan — the guard cannot be driven, and a skip here would certify nothing"
    echo "reopen-is-history-not-loss: $pass passed, $fail failed"
    exit 1
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/reopen-history.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

build_tree() {
    _t="$W/$1"
    mkdir -p "$_t/scripts/lib" "$_t/plan/index.d"
    cp "$ROOT/scripts/check-fragment-status-loss.sh" "$_t/scripts/"
    cp "$ROOT/scripts/plan-binary-probe.sh" "$_t/scripts/" 2>/dev/null || true
    cp "$ROOT/scripts/lib/tool-dispatch.sh" "$_t/scripts/lib/" 2>/dev/null || true
    printf 'plan_index:\n  steps:\n    - packet_id: probe-reopen-subject\n      order: 9990-aaaa\n      status: %s\n      title: the packet under test\n' "$2" \
        > "$_t/plan/index.yaml"
}
add_frag() { printf '%s' "$3" > "$W/$1/plan/index.d/$2"; }
run_guard_in() {
    ( cd "$W/$1" && TILLANDSIAS_PLAN_BIN="$PLAN_BIN" bash scripts/check-fragment-status-loss.sh 2>&1 )
}
folded_status() {
    ( cd "$W/$1" && "$PLAN_BIN" status probe-reopen-subject 2>/dev/null | awk '{print $2}' )
}

# ── ARM 1: A SANCTIONED REOPEN IS ACCEPTED. ────────────────────────────────
# The real shape, as `set-field --reopen-evidence` writes it: an EARLIER
# fragment closed the packet, a LATER one walks the status back and carries the
# falsified event that authorises the walk-back.
build_tree reopen completed
add_frag reopen 20260101t000000z-aaaaaaaa-probe.yaml 'events:
  - packet_id: probe-reopen-subject
    event:
      type: completed
      ts: "2026-01-01T00:00:00Z"
      host: probe
      summary: the original closure
'
add_frag reopen 20260201t000000z-bbbbbbbb-probe.yaml 'status:
  - packet_id: probe-reopen-subject
    field: status
    value: in_progress
    ts: "2026-02-01T00:00:00Z"
    host: probe

events:
  - packet_id: probe-reopen-subject
    event:
      type: falsified
      ts: "2026-02-01T00:00:00Z"
      host: probe
      summary: the falsifying observation that authorises the reopen
'
got="$(folded_status reopen)"
if [ "$got" != "in_progress" ]; then
    bad "ARM 1 PRECONDITION: the scratch ledger folds as '$got', not in_progress — the reopen never happened, so any verdict below is about the wrong shape"
else
    out="$(run_guard_in reopen)"
    if printf '%s' "$out" | grep -q 'violation:fragment-status-loss'; then
        bad "ARM 1: a sanctioned reopen is still refused, so no host can land a correction: $(printf '%s' "$out" | grep -m1 'probe-reopen-subject')"
    else
        ok "ARM 1: a reopen (closure OLDER than the transition) is accepted as history"
    fi
fi

# ── ARM 2: THE NEGATIVE CONTROL — AN UNAPPLIED CLOSURE IS STILL REFUSED. ───
build_tree unapplied ready
add_frag unapplied 20260301t000000z-cccccccc-probe.yaml 'events:
  - packet_id: probe-reopen-subject
    event:
      type: completed
      ts: "2026-03-01T00:00:00Z"
      host: probe
      summary: a closure whose status transition never landed
'
got="$(folded_status unapplied)"
if [ "$got" != "ready" ]; then
    bad "ARM 2 PRECONDITION: the scratch ledger folds as '$got', not ready — this is no longer an unapplied closure"
else
    out="$(run_guard_in unapplied)"
    if printf '%s' "$out" | grep -q 'violation:fragment-status-loss'; then
        ok "NEGATIVE CONTROL: an unapplied closure (no transition) is still refused"
    else
        bad "NEGATIVE CONTROL BREACHED: a terminal event with no status transition PASSED. The fix widened what is accepted instead of comparing timestamps, and the guard no longer catches the case it exists for (11 of 21 packets on 2026-08-09)"
    fi
fi

# ── ARM 3: A CLOSURE RACING A REOPEN IS REFUSED. ───────────────────────────
build_tree racing completed
add_frag racing 20260401t000000z-dddddddd-probe.yaml 'status:
  - packet_id: probe-reopen-subject
    field: status
    value: in_progress
    ts: "2026-04-01T00:00:00Z"
    host: probe

events:
  - packet_id: probe-reopen-subject
    event:
      type: falsified
      ts: "2026-04-01T00:00:00Z"
      host: probe
      summary: the reopen
'
add_frag racing 20260501t000000z-eeeeeeee-probe.yaml 'events:
  - packet_id: probe-reopen-subject
    event:
      type: completed
      ts: "2026-05-01T00:00:00Z"
      host: probe
      summary: a closure landing AFTER the reopen
'
got="$(folded_status racing)"
if [ "$got" != "in_progress" ]; then
    bad "ARM 3 PRECONDITION: the scratch ledger folds as '$got', not in_progress — the reopen this closure is supposed to race never happened"
else
    out="$(run_guard_in racing)"
    if printf '%s' "$out" | grep -q 'violation:fragment-status-loss'; then
        ok "ARM 3: a terminal event NEWER than the transition is refused (a race, not history)"
    else
        bad "ARM 3: a closure that POSTDATES a reopen was accepted — the comparison is inverted or absent"
    fi
fi

echo "reopen-is-history-not-loss: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

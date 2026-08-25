#!/usr/bin/env bash
# @trace order:719-kgr5, spec:methodology-accountability
set -uo pipefail

# Fixture for the ledger timestamp skew guard (order 719-kgr5).
#
# THE BREACH: across the 2026-08-13 windows overnight run, `--ts` values were
# hand-authored — incremented about an hour per cycle from an early guess —
# instead of read from the clock, drifting to +8.6h against the real commit
# times while the sibling linux host stayed within 17 seconds. The ledger folds
# fragments in NAME order, expires claims from event timestamps, and reports
# rolling metrics over them, so the writes were not merely untidy: they sorted
# this host's work after later work and could outlive a claim's TTL.
#
# The tooling accepted `--ts` on trust, which made ordering a property of agent
# discipline. Discipline failed for eleven consecutive cycles without one thing
# noticing. These scenarios prove the tool notices now.
#
# Hermetic: every write targets a throwaway ledger under TMPDIR. Nothing here
# touches plan/index.yaml or plan/loop_status.d.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/plan-binary-probe.sh"
cd "$ROOT" || exit 2
PLAN="$(resolve_plan_binary)" || { echo "refused:no-plan-binary — build tillandsias-plan first"; exit 2; }
PLAN="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

work="$(mktemp -d "${TMPDIR:-/tmp}/ledger-ts-guard-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 772-4se9: append-event now REFUSES when no --agent is passed and
# TILLANDSIAS_AGENT_ID is unset (it used to fabricate agent_id=unknown).
# These scenarios exercise the TIMESTAMP guard, so identity is provided
# once here to keep every verdict below about its own subject. 874-idnt:
# the id must now satisfy the canonical grammar (agent-identity.sh shape,
# trailing lowercase timestamp) — a bare label like the old
# "ledger-ts-guard-fixture" is refused at write time.
export TILLANDSIAS_AGENT_ID="linux-fixture-ledger-ts-guard-20260101t000000z"

index="$work/index.yaml"
cat >"$index" <<'YAML'
packets:
  - packet_id: fixture-packet
    order: 000-test
    status: ready
    title: A packet that exists only for this fixture
    kind: bug
YAML
mkdir -p "$work/index.d"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# Offset the clock by N seconds, in the exact shape the ledger writes.
# GNU then BSD (-r). Without the BSD arm every offset came back EMPTY on
# macOS, every scenario fed `--ts ''`, and the guard's own fixture reported
# six failures that said nothing about the guard — a fixture for a
# fail-loud mechanism, failing quietly for the wrong reason (784-dwkh).
iso_offset() {
    _e=$(( $(date -u +%s) + $1 ))
    date -u -d "@${_e}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${_e}" +%Y-%m-%dT%H:%M:%SZ
}

failures=()

# run <name> <expect-exit> <want-substring> -- <plan args...>
run() {
    local name="$1" want_rc="$2" want="$3"; shift 4
    local rc=0 out
    out="$("$PLAN" --index "$index" "$@" 2>&1)" || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        failures+=("$name: exit=$rc expected=$want_rc (out: $out)")
    elif [ -n "$want" ] && ! printf '%s' "$out" | grep -Fq "$want"; then
        failures+=("$name: expected '$want', got: $out")
    fi
}

# 1. THE BREACH SHAPE: a timestamp 8.6 hours ahead of the host clock, which is
#    what eleven cycles wrote. Must be refused, naming BOTH values — the symptom
#    was misdiagnosed once already as "your clock is 7 hours ahead of UTC", and
#    a refusal that named only one number would invite the same wrong reading.
run "future-drift-refused" 2 "disagrees with this host's clock" -- \
    append-event fixture-packet progress "invented timestamp" --ts "$(iso_offset 31000)"

# 2. Symmetric: a value hours BEHIND is equally wrong and equally refused.
run "past-drift-refused" 2 "disagrees with this host's clock" -- \
    append-event fixture-packet progress "stale timestamp" --ts "$(iso_offset -31000)"

# 3. NEGATIVE CONTROL: a legitimate in-skew timestamp still writes. Without
#    this the guard could degrade into refusing every explicit --ts and still
#    look like it was working.
run "in-skew-accepted" 0 "" -- \
    append-event fixture-packet progress "read from the clock" --ts "$(now_iso)"

# 4. NEGATIVE CONTROL: omitting --ts is now the easy path and must work. The
#    old interface REQUIRED the flag on the reasoning that "the tool does not
#    invent timestamps", which only moved the invention to the caller.
run "absent-ts-defaults-to-clock" 0 "" -- \
    append-event fixture-packet progress "no --ts at all"

# 5. The escape hatch: a genuine backfill reaches backward, explicitly.
run "backfill-accepted" 0 "" -- \
    append-event fixture-packet note "recording something from this morning" \
    --ts "$(iso_offset -31000)" --backfill

# 6. …but never forward. A flag that also waived future timestamps would hand
#    the original defect a one-word bypass.
run "backfill-refuses-future" 2 "AHEAD of this host's clock" -- \
    append-event fixture-packet note "not a backfill" --ts "$(iso_offset 31000)" --backfill

# 7. A malformed timestamp is refused rather than half-read: an unparsed value
#    would otherwise become an unmeasured skew.
run "malformed-ts-refused" 2 "is not a ledger timestamp" -- \
    append-event fixture-packet note "bad shape" --ts "2026-08-13 22:05:00"

# 8. The same rule on the OTHER writers, because a guard on one surface is a
#    detour, not a constraint. set-field first:
run "set-field-drift-refused" 2 "disagrees with this host's clock" -- \
    set-field fixture-packet priority p1 --reason fixture --ts "$(iso_offset 31000)"

# 9. …and loop-status-append, where the stamp becomes the fragment NAME and so
#    determines fold order directly.
ls_rc=0
ls_out="$(printf '## Cycle drift test\n\n- body\n' |
    "$PLAN" --index "$index" loop-status-append --host fixture --ts "$(iso_offset 31000)" 2>&1)" || ls_rc=$?
if [ "$ls_rc" -ne 2 ]; then
    failures+=("loop-status-drift-refused: exit=$ls_rc expected=2 (out: $ls_out)")
elif ! printf '%s' "$ls_out" | grep -Fq "disagrees with this host's clock"; then
    failures+=("loop-status-drift-refused: expected clock-disagreement verdict, got: $ls_out")
fi

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "ledger-ts-guard: FAIL ${#failures[@]} scenario(s) did not match expected verdicts"
    exit 1
fi
echo "PASS: ledger-ts-guard fixture 9/9 scenarios green (future-drift, past-drift, in-skew, absent-ts, backfill, backfill-future, malformed, set-field, loop-status-append)"

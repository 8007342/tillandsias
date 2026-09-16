#!/usr/bin/env bash
# @trace order:1201-9it2, order:748-tkjx, spec:ci-release
#
# test-land-notice-names-unrun-litmus.sh — before a push, the land tool names the
# litmus arms asserting on the changed files that ./build.sh --check did not run.
#
# WHY A NOTICE AND NOT A GATE. ./build.sh --check executes NO litmus, and that is
# deliberate: build.sh:2508 (748-tkjx) says the suite is minutes and "a gate that
# slow gets bypassed with --no-verify". Closing a VISIBILITY gap by slowing the
# gate trades it for a bypass problem, which is strictly worse AND unmeasurable
# once it starts, because the evidence of a bypass is the absence of a run. So
# this refuses nothing; it only stops the author deciding blind.
#
# THE SILENCE HAS COST THREE INSTANCES, all recorded rather than argued:
#   2026-08-15  images/default/lib-common.sh left litmus:startup-context-addendum-shape red
#   2026-08-28  921-vtf4 found three tests red back to af745f3fd
#   2026-09-15  4fc7be930 bumped WIRE_VERSION 3 -> 4 against a pin of 3; the red
#               was found three hours later by 890-27mv's cadence, not by the gate
#
# NO NEW MACHINERY: 748-tkjx already built the reverse map
# (scripts/litmus-covering-specs.sh) for exactly this question. The only thing
# missing was asking it at the moment of the push.
#
# ARM 2 IS THE LOAD-BEARING ONE. The notice is worth nothing if it cannot name
# the arm that actually went red, so it is asserted against the REAL commit that
# motivated the row rather than against a synthetic input.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

LAND="$ROOT/scripts/land-on-platform-branch.sh"
MAP="$ROOT/scripts/litmus-covering-specs.sh"
[ -f "$LAND" ] || { echo "skip:land-notice:$LAND absent"; exit 3; }
[ -x "$MAP" ]  || { echo "skip:land-notice:$MAP absent"; exit 3; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

echo "arm 1 — the land tool emits the notice BEFORE the push, and refuses nothing"
if grep -q '1201-9it2' "$LAND" && grep -q 'litmus-covering-specs.sh' "$LAND"; then
    # Order matters: a notice printed after the push is a report, not a notice.
    _n="$(grep -n 'NOTICE — ' "$LAND" | head -1 | cut -d: -f1)"
    _p="$(grep -n 'attempt \$attempt — push' "$LAND" | head -1 | cut -d: -f1)"
    if [ -n "$_n" ] && [ -n "$_p" ] && [ "$_n" -lt "$_p" ]; then
        ok "the notice is emitted before the push line ($_n < $_p)"
    else
        bad "the notice does not precede the push (notice=$_n push=$_p) — after the push it is a report, not a notice"
    fi
else
    bad "the land tool no longer consults the covering-specs map"
fi

echo "arm 2 — it names the arm that actually went RED on the motivating commit"
# 4fc7be930 bumped WIRE_VERSION 3 -> 4 while
# litmus:guest-container-metrics-wire-shape pinned 3. If the notice cannot name
# that arm from that commit's changed paths, it would not have helped and this
# whole row is decoration.
if git cat-file -e 4fc7be930^{commit} 2>/dev/null; then
    _out="$(git diff --name-only 4fc7be930^ 4fc7be930 | xargs -r bash "$MAP" 2>/dev/null)"
    if printf '%s\n' "$_out" | grep -q 'guest-container-metrics-wire-shape'; then
        ok "names litmus:guest-container-metrics-wire-shape from that commit's paths"
    else
        bad "the notice would NOT have named the red arm — it would not have helped"
    fi
else
    echo "  skip: 4fc7be930 not present in this clone (shallow?), cannot assert the counterfactual"
fi

echo "arm 3 — CONTROL: a change touching nothing litmus-covered says nothing"
# Silence when there is nothing to say. A notice that fires on every push is
# noise, and a reader learns to skip it — which is the same end state as no
# notice at all, reached more expensively.
_tmpf="$(mktemp -d)/plan-only-probe.md"
mkdir -p "$(dirname "$_tmpf")"
printf 'prose\n' > "$_tmpf"
_none="$(bash "$MAP" "$_tmpf" 2>/dev/null | awk -F'\t' '$2 ~ /^spec:/' | grep -c . || true)"
if [ "${_none:-0}" -eq 0 ]; then
    ok "an uncovered path yields no spec lines, so the notice stays silent"
else
    bad "an uncovered path produced $_none spec line(s); the notice would fire on everything"
fi
rm -rf "$(dirname "$_tmpf")"

echo "arm 4 — CONTROL: the notice's exit status cannot fail a land"
# It is advisory BY CONSTRUCTION, not by intention: the map's status is swallowed
# and the block cannot exit non-zero.
if grep -A 12 'NOTICE — ' "$LAND" | grep -q 'exit 1\|exit 3\|return 1'; then
    bad "the notice block can exit non-zero — it would refuse a land, which 748-tkjx says is the wrong trade"
else
    ok "no failing exit inside the notice block; it cannot refuse a land"
fi

echo "arm 5 — the reason is recorded where the next reader will be, not only in a packet"
if grep -q '748-tkjx' "$LAND"; then
    ok "the land tool cites 748-tkjx, so a reader learns why --check ran none of them"
else
    bad "nothing in the land tool says why these arms were not run"
fi

echo
echo "land notice for unrun litmus: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:land-notice:$fail"
    exit 1
fi
echo "ok:land-notice:$pass"
exit 0

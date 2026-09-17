#!/usr/bin/env bash
# @trace order:1221-vkbj, order:1141-vf9w, order:1150-q462, spec:ci-release
#
# test-competing-gate-no-dispatch-cause.sh — a silence names WHICH silence, and
# build.sh reads the code instead of discarding it.
#
# THE DEFECT, measured on lenovinha 2026-09-16 by running build.sh's own
# invocation by hand rather than by reading it:
#
#     bash scripts/check-no-competing-gate.sh
#     could-not-run:competing-gate:no-host-side-assertion
#       (this caller did not assert --host-side <pid>; ...)          rc=3
#     TOOLBOX_PATH=<unset> container=<unset> TILLANDSIAS_WRAPPER_TOKEN=<unset>
#
# That token is this file's vocabulary for a caller that OMITTED something, and
# its sibling refusal says "FIX THE CALL SITE" outright. It was printed on a
# host where no dispatch existed to have a host side — nothing to fix — and then
# discarded by `|| true`. So the detector 1141-vf9w built to be "exercised every
# gate" was, at the one site that runs every gate, never exercised at all.
#
# ARMS 4-7 ARE THE LOAD-BEARING HALF. The over-correction here is worse than the
# defect, in two distinct ways, and both are pinned:
#
#   - a new cause that SWALLOWS wiring bugs. If `no-dispatch` becomes the answer
#     for any caller that did not assert, a wrapper that forgot its --host-side
#     stops being loud and 1140-i6ct's collapse is back.
#   - a vacuous CLEAN. Letting an undispatched caller assert --host-side yields
#     the only verdict its classifier can reach with one process and no container
#     side: ok:no-competing-gate. 1141-vf9w's promotion criterion is "once it has
#     run clean across hosts", so that green would be consumed as evidence for
#     making this check refuse. Arm 6 pins that build.sh never does it.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
CHECK="$ROOT/scripts/check-no-competing-gate.sh"
[ -x "$CHECK" ] || { echo "skip:no-dispatch-cause:check-no-competing-gate.sh absent"; exit 3; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# run <args...> ; sets RC and OUT. env -u so an inherited token cannot leak in.
run() { OUT="$(env -u TILLANDSIAS_WRAPPER_TOKEN bash "$CHECK" "$@" 2>&1)"; RC=$?; }

echo "arm 1 — an UNDISPATCHED caller gets a cause naming that, not a missing assertion"
run --caller-context undispatched
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'competing-gate:no-dispatch'; then
    ok "could-not-run:competing-gate:no-dispatch (rc=3)"
else
    bad "expected no-dispatch at rc=3; rc=$RC out=$(printf '%s' "$OUT" | head -1)"
fi
if printf '%s' "$OUT" | grep -qi 'NOTHING TO FIX HERE'; then
    ok "and says there is nothing to fix, so it is not read as a wiring bug"
else
    bad "the cause does not distinguish itself from FIX THE CALL SITE"
fi

echo "arm 2 — a caller INSIDE the dispatch gets its own cause"
run --caller-context dispatched
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'competing-gate:inside-dispatch'; then
    ok "could-not-run:competing-gate:inside-dispatch (rc=3)"
else
    bad "expected inside-dispatch at rc=3; rc=$RC out=$(printf '%s' "$OUT" | head -1)"
fi

echo "arm 3 — the two causes are DIFFERENT strings"
run --caller-context undispatched; a="$OUT"
run --caller-context dispatched;   b="$OUT"
if [ "$a" != "$b" ]; then
    ok "a reader can tell which silence this is"
else
    bad "both contexts print the same line — the row's whole subject is unfixed"
fi

echo "arm 4 — NEGATIVE CONTROL: a caller asserting NOTHING still gets the loud old cause"
# Otherwise the new token becomes a bucket that swallows genuine wiring bugs.
run
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'no-host-side-assertion'; then
    ok "unchanged: no-host-side-assertion (rc=3) — a wrapper that forgot is still visible"
else
    bad "the omitting caller's message changed; rc=$RC out=$(printf '%s' "$OUT" | head -1)"
fi

echo "arm 5 — NEGATIVE CONTROL: a bad context value is a CALLER CONTRACT refusal, not a substrate limit"
run --caller-context sideways
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'caller-contract'; then
    ok "refused:competing-gate:caller-contract (rc=2) — 2 stays distinct from 3"
else
    bad "a typo'd context did not refuse at rc=2; rc=$RC out=$(printf '%s' "$OUT" | head -1)"
fi

echo "arm 6 — NEGATIVE CONTROL: build.sh must NOT assert --host-side, which would manufacture a vacuous clean"
# With no dispatch the classifier has one process and no container side, so
# ok:no-competing-gate is the only verdict it can reach — and 1141-vf9w's
# promotion criterion ("run clean across hosts") would consume it as evidence.
if grep -n 'check-no-competing-gate.sh' "$ROOT/build.sh" | grep -q 'host-side'; then
    bad "build.sh asserts --host-side; on an undispatched host that green is vacuous"
else
    ok "build.sh asserts context only — no verdict is manufactured"
fi

echo "arm 7 — NEGATIVE CONTROL: asserting --host-side AND a context is a caller-contract refusal"
run --host-side $$ --caller-context undispatched
if [ "$RC" -eq 2 ]; then
    ok "the two assertions cannot silently outrank each other"
else
    bad "a caller asserting both was answered; rc=$RC"
fi

echo "arm 8 — build.sh READS the code: 2 is enumerated apart from 3, with no default that proceeds"
# ANCHOR ON THE INVOCATION, NOT ON A RANGE. The first draft of this arm took
# sed '/check-no-competing-gate.sh/,/esac/p', which on the pre-fix tree spans
# 921 lines and sweeps up four unrelated `|| true`s — a window that wide scores
# the rest of build.sh, not this call site, and it answered inconsistently
# between the fixed and pre-fix trees for exactly that reason. The window is now
# the invocation line plus the handler that follows it.
_cg_line="$(grep -n '_run bash .*check-no-competing-gate\.sh' "$ROOT/build.sh" | head -1 | cut -d: -f1)"
if [ -z "$_cg_line" ]; then
    bad "no check-no-competing-gate.sh invocation found in build.sh"
    _cg_line=1
fi
site="$(sed -n "${_cg_line},$((_cg_line + 14))p" "$ROOT/build.sh")"
if printf '%s' "$site" | grep -q '|| true'; then
    bad "build.sh still discards the exit code with \`|| true\` (1150-q462)"
else
    ok "the exit code is captured, not discarded"
fi
if printf '%s' "$site" | grep -qE '^ *2\)' && printf '%s' "$site" | grep -qE '^ *3\)' \
   && printf '%s' "$site" | grep -qE '^ *\*\)'; then
    ok "2, 3 and an unknown-code arm are each handled"
else
    bad "the consumer does not enumerate 2 apart from 3 with an unknown-code arm"
fi

echo "arm 9 — the check stays ADVISORY: this row changed what is said and read, never whether a gate refuses"
if grep -q 'TILLANDSIAS_COMPETING_GATE_ADVISORY' "$CHECK" \
   && ! printf '%s' "$site" | grep -qE '^ *(2|3)\).*exit '; then
    ok "no exit path was added at the call site; 1141-vf9w's staging is untouched"
else
    bad "the consumer can now end the gate — that is 1141-vf9w's decision to make, not this row's"
fi

echo
echo "competing-gate no-dispatch cause: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:no-dispatch-cause:$fail"
    exit 1
fi
echo "ok:no-dispatch-cause:$pass"
exit 0

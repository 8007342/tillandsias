#!/usr/bin/env bash
# @trace order:1009-gccx
#
# test-gate-fast-refusals.sh — the gate must refuse a sub-second-decidable
# defect BEFORE it compiles anything.
#
# WHY. A fifth to a third of gate runs end red, and the checks that end them
# are decidable in milliseconds — but they used to run after everything
# expensive. MEASURED on lenovinha 2026-09-04 with one planted exec-bit defect,
# TILLANDSIAS_FORCE_CHECK=1 both times, same verdict both times:
#     before the reorder   222s to refusal
#     after                  2s to refusal
# The defect was a dropped exec bit, which is not hypothetical: an awk rewrite
# dropped one on scripts/local-ci.sh the same day and cost both macbookair and
# lenovinha a full gate run to be told in 92ms.
#
# WHAT THIS PINS, and it is the ORDER rather than any single check: that a
# planted cheap defect is refused with NO compile phase having been entered.
# Asserting only "the gate refuses" would pass just as well with the guard back
# at the end of the run, which is the state this order exists to leave.
#
# THE MEMO MUST BE BYPASSED (765-tkq2). The gate memoises on tree bytes plus
# toolchain, and a chmod changes neither — so without TILLANDSIAS_FORCE_CHECK=1
# a planted exec-bit defect returns a 2s GREEN from the memo and the fixture
# would "pass" while testing nothing. That is not a hypothetical either: it is
# exactly what my first attempt at this measurement did, and the number looked
# plausible.

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

VICTIM="scripts/check-litmus-pin-claims.sh"
if [ ! -f "$VICTIM" ]; then
    echo "skip:test-gate-fast-refusals:victim-absent:$VICTIM"
    exit 0
fi

# The fast-refusal phase must exist and must precede the first compile step.
# Checked as TEXT first, because it is instant and it localises a regression to
# "the phase moved" rather than to a slow gate run.
_fast_line="$(/usr/bin/grep -n 'Fast refusals: sub-second deciders' build.sh 2>/dev/null | head -1 | cut -d: -f1)"
_clippy_line="$(/usr/bin/grep -n '_step "Running clippy (strict; includes the workspace type-check)' build.sh 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "$_fast_line" ] && [ -n "$_clippy_line" ] && [ "$_fast_line" -lt "$_clippy_line" ]; then
    ok "the fast-refusal phase is declared before the first compile step"
else
    bad "fast-refusal phase missing or after the first compile (fast=$_fast_line clippy=$_clippy_line)"
fi

# Each guard the phase claims must be invoked exactly once in build.sh — a
# duplicate would run the check twice per gate, which is how a "move" that was
# really a copy hides.
#
# COUNT INVOCATIONS, NOT MENTIONS. The first draft grepped for the bare script
# name and immediately produced a false positive: 1034-ihxw added a comment
# explaining why check-declared-closures-added.sh is deliberately NOT hoisted,
# and the prose mention counted as a second call site. That is the same defect
# the 901-jtvi lint had to fix — a rule keyed on a string appearing rather than
# on a caller — reproduced here within hours. Match the `_run bash ...` form.
for g in check-scorable-obligation-added check-issue-citation-convention \
         check-script-exec-bits check-litmus-pin-claims; do
    n="$(/usr/bin/grep -cE "_run bash .*$g\.sh" build.sh 2>/dev/null || echo 0)"
    [ "$n" = "1" ] || bad "$g.sh is invoked $n times in build.sh (expected exactly 1)"
done

# 885-92iu is the exception, and the exception is the point (1034-ihxw): it
# degrades to a SKIP when `tillandsias-plan` is unbuilt, so hoisting it above
# the build turned a gate into a no-op on a cold tree. It must be invoked
# exactly once and AFTER the first compile.
_dc="$(/usr/bin/grep -nE '_run bash .*check-declared-closures-added\.sh' build.sh 2>/dev/null | head -1 | cut -d: -f1)"
_dc_n="$(/usr/bin/grep -cE '_run bash .*check-declared-closures-added\.sh' build.sh 2>/dev/null || echo 0)"
if [ "$_dc_n" != "1" ]; then
    bad "check-declared-closures-added.sh is invoked $_dc_n times (expected exactly 1)"
elif [ -n "$_dc" ] && [ -n "$_clippy_line" ] && [ "$_dc" -gt "$_clippy_line" ]; then
    ok "885-92iu stays AFTER the first compile (it skips without a built binary)"
else
    bad "885-92iu is invoked at line $_dc, at or before the first compile ($_clippy_line) — it would skip on a cold tree"
fi
[ "$fail" -eq 0 ] && ok "each hoisted guard is invoked exactly once"

# ── the behavioural arm, opt-in ─────────────────────────────────────────────
# A full forced gate is minutes, so this arm runs only when asked. The static
# arms above are what --ci-full pays for; this is what a human runs to confirm
# the property end to end.
if [ "${TILLANDSIAS_GATE_FAST_REFUSAL_E2E:-0}" != "1" ]; then
    echo "  note: behavioural arm skipped (set TILLANDSIAS_GATE_FAST_REFUSAL_E2E=1; it runs a forced gate)"
else
    _restore() { chmod +x "$VICTIM" 2>/dev/null || true; }
    trap _restore EXIT
    chmod -x "$VICTIM"
    _log="$(mktemp)"
    _t0="$(date +%s)"
    TILLANDSIAS_FORCE_CHECK=1 timeout 1800 ./build.sh --check > "$_log" 2>&1
    _rc=$?
    _t1="$(date +%s)"
    _restore
    _elapsed=$(( _t1 - _t0 ))
    if [ "$_rc" -eq 0 ]; then
        bad "behavioural: the gate PASSED a tree with a non-executable invoked script (rc=0, ${_elapsed}s)"
    elif ! /usr/bin/grep -q 'violation:script-not-executable' "$_log"; then
        bad "behavioural: refused for some other reason, not the planted defect"
    elif /usr/bin/grep -q 'Running clippy' "$_log"; then
        bad "behavioural: refused (${_elapsed}s) but only AFTER compiling — the reorder is not in effect"
    else
        ok "behavioural: planted defect refused in ${_elapsed}s with no compile entered"
    fi
    rm -f "$_log"
fi

printf 'gate-fast-refusals: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "fail:test-gate-fast-refusals:$fail"; exit 1; }
echo "ok:test-gate-fast-refusals:$pass"

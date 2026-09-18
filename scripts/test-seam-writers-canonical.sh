#!/usr/bin/env bash
# @trace order:1251-54p3
#
# test-seam-writers-canonical.sh — fixture for check-seam-writers-canonical.sh.
#
# Four arms, all hermetic: they build small trees under a tempdir rather than
# asserting anything about the live checkout, so this fixture does not go red
# when 1250-92ty lands and remote_projects stops being a violator.
#
# ARM 2 is the one that justifies the guard: it reconstructs the PRE-FIX shape
# (a module writing the seam var under a mutex of its own) and asserts the check
# NAMES that module. That is the real defect, caught before any test runs.
#
# ARM 3b is the blindness probe. The guard strips `//` before matching; the
# probe LEAVES the comment in place, so the arm exercises the blindness rather
# than asserting its absence. A guard that merely claimed to ignore comments
# would pass a test that never fed it one.
set -u

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-seam-writers-canonical.sh"
VAR="TILLANDSIAS_PODMAN_BIN"
CANON="podman_seam_lock"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

writer_file() {  # $1=path  $2=extra line
    mkdir -p "$(dirname "$1")"
    {
        echo 'fn seam() {'
        echo "    unsafe { std::env::set_var(\"$VAR\", \"/bin/false\") };"
        echo '}'
        [ -n "${2:-}" ] && echo "$2"
    } > "$1"
}

# ARM 1 — a writer with NO canonical reference is refused and NAMED.
a1="$tmp/a1/src"; writer_file "$a1/lonely.rs" ""
out="$(bash "$CHECK" "$a1" "$VAR" "$CANON" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "refused:seam-writer-uncanonical:.*lonely.rs"; then
    pass "ARM 1: an uncanonical writer is refused and named"
else
    fail "ARM 1: expected refusal naming lonely.rs, got rc=$rc: $out"
fi

# ARM 2 — THE PRE-FIX SHAPE. Two modules write the var; one uses the canonical
# lock, the other guards it with a private mutex. The private one must be named.
a2="$tmp/a2/src"
writer_file "$a2/main.rs" "fn l() { let _g = crate::runtime_assets::${CANON}(); }"
writer_file "$a2/accel_probe.rs" 'fn l() { static SEAM_LOCK: Mutex<()> = Mutex::new(()); let _g = SEAM_LOCK.lock(); }'
out="$(bash "$CHECK" "$a2" "$VAR" "$CANON" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "accel_probe.rs" \
   && ! printf '%s' "$out" | grep -q "refused:seam-writer-uncanonical:.*main.rs"; then
    pass "ARM 2: the private-mutex module is named, the canonical one is not"
else
    fail "ARM 2: expected accel_probe.rs named and main.rs clean, got rc=$rc: $out"
fi

# ARM 3a — a real CODE reference satisfies the check.
a3="$tmp/a3/src"; writer_file "$a3/ok.rs" "fn l() { let _g = crate::runtime_assets::${CANON}(); }"
out="$(bash "$CHECK" "$a3" "$VAR" "$CANON" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "^ok:seam-writers-canonical:1$"; then
    pass "ARM 3a: a real code reference passes"
else
    fail "ARM 3a: expected ok:seam-writers-canonical:1, got rc=$rc: $out"
fi

# ARM 3b — the SAME symbol, present only inside a comment, must NOT satisfy it.
a3b="$tmp/a3b/src"; writer_file "$a3b/commented.rs" "// serialised by ${CANON}, honest"
out="$(bash "$CHECK" "$a3b" "$VAR" "$CANON" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "refused:seam-writer-uncanonical:.*commented.rs"; then
    pass "ARM 3b: a comment-only reference does NOT satisfy the check"
else
    fail "ARM 3b: a commented lock name was accepted as a real one, rc=$rc: $out"
fi

# ARM 4 — POSITIVE CONTROL. No writers at all must refuse, never report ok:0.
a4="$tmp/a4/src"; mkdir -p "$a4"; echo 'fn nothing() {}' > "$a4/empty.rs"
out="$(bash "$CHECK" "$a4" "$VAR" "$CANON" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "refused:seam-var-has-no-writers:$VAR"; then
    pass "ARM 4: a vanished target refuses rather than passing vacuously"
else
    fail "ARM 4: expected refused:seam-var-has-no-writers, got rc=$rc: $out"
fi

# ARM 5 — CARDINALITY. THE COUNT IS THE ASSERTION; do not trim this to a
# non-emptiness check. ARM 4 asks "did I see ANYTHING?" and therefore catches
# only TOTAL blindness. Under PARTIAL blindness one writer survives, the list is
# non-empty, ARM 4 never fires, and the guard prints a clean `ok:` while blind to
# the rest. Measured 2026-09-17: a `| grep -q` form of this check reported
# `ok:seam-writers-canonical:1` on a tree with THREE writers, blind to both
# modules the seam race actually involved. The only difference from a correct
# run was the number.
#
# ONE WRITER IS DELIBERATELY LARGE. The failure this arm exists to catch is a
# RACE — the producer streaming a file against a consumer exiting on its first
# match — so it needs a file big enough that the producer is still writing.
#
# HOW MUCH BIG IS ENOUGH IS NOT PORTABLE, AND THAT IS THE POINT. The race is
# decided by filesystem SPEED as well as size. The same 28,711-line file was
# read fast enough to be safe on a local-filesystem Linux host and slow enough
# to go INVISIBLE on a Windows host driving WSL over a 9P bridge (~38x penalty),
# where the break was already under 8,081 lines. So no line count is a boundary,
# and this arm is honest about what it is: it HAS TEETH on a slow filesystem and
# is a cheap invariant on a fast one. ARM 6 is the portable half.
a5="$tmp/a5/src"
writer_file "$a5/small_a.rs" "fn l() { let _g = crate::runtime_assets::${CANON}(); }"
writer_file "$a5/small_b.rs" "fn l() { let _g = crate::runtime_assets::${CANON}(); }"
writer_file "$a5/large.rs"   "fn l() { let _g = crate::runtime_assets::${CANON}(); }"
# Real source lines, not short filler: filler streams far more cheaply and
# overestimated the threshold by more than an order of magnitude when measured.
i=0
while [ "$i" -lt 40000 ]; do
    echo "    let _padding_${i} = \"a moderately long source line, as real code is\";"
    i=$((i + 1))
done >> "$a5/large.rs"
# RUN IT UNDER `-o pipefail`, which is the whole point. The inversion requires
# pipefail to be in effect; invoking the check in a plain shell cannot exercise
# it at all, and an earlier draft of this arm was green against a deliberately
# sabotaged check for exactly that reason — it was asserting cardinality without
# ever reaching the code path that breaks it. `bash -o pipefail` stands in for
# the future caller who adds the option, or sources this from a stricter script.
out="$(bash -o pipefail "$CHECK" "$a5" "$VAR" "$CANON" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "^ok:seam-writers-canonical:3$"; then
    pass "ARM 5: all three writers counted under pipefail, the large one included"
else
    fail "ARM 5: expected exactly 3 writers under pipefail, got rc=$rc: $out"
fi

# ARM 6 — SHAPE, and this is the arm that has teeth on EVERY host. Because the
# ARM 5 race is decided by filesystem speed, a guard built on `producer | grep -q`
# cannot be validated by behaviour on any single machine: the host where it
# silently fails is the SLOW one, which is the floor-tier machine least able to
# notice and most likely to be trusted, since it runs identical code. What IS
# portable is the SHAPE. `grep -q` exits on first match and SIGPIPEs the
# producer; under `set -o pipefail` the pipeline then reports FAILURE ON A MATCH.
# So forbid the construct in this file outright rather than waiting for a host
# slow enough to demonstrate it (order 795-imz3, which flags `if ! <pipeline>`
# and does NOT match the `| grep -qE ... &&` sibling that failed first here).
#
# FULL-LINE COMMENTS are dropped first, because the checked script's own header
# discusses `grep -q` in prose and a guard that matched its own documentation
# would be useless. Note the comment syntax: that file is SHELL (`#`), not Rust
# (`//`) — the first draft of this arm reused the Rust idiom and reported a
# false positive on a comment.
#
# Only WHOLE comment lines are removed, deliberately. Stripping from the first
# `#` onward would truncate lines at a `#` inside a parameter expansion or
# string and could HIDE a real `| grep -q` after it — a false NEGATIVE in a
# guard, which is strictly worse than the false positive it would cure. A
# trailing comment after real code is harmless here: the code precedes it and
# still matches.
shape_hits="$(grep -vE '^[[:space:]]*#' "$CHECK" | grep -cE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' || true)"
if [ "${shape_hits:-0}" -eq 0 ]; then
    pass "ARM 6: the check contains no SIGPIPE-prone \`| grep -q\` pipeline"
else
    fail "ARM 6: $shape_hits pipeline(s) pipe into grep -q; capture then match instead"
fi

if [ "$fails" -eq 0 ]; then
    echo "ok:seam-writers-canonical-fixture:7"
    exit 0
fi
echo "refused:seam-writers-canonical-fixture:$fails-arm(s)-failed"
exit 1

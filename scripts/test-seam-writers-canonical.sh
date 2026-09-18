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

if [ "$fails" -eq 0 ]; then
    echo "ok:seam-writers-canonical-fixture:5"
    exit 0
fi
echo "refused:seam-writers-canonical-fixture:$fails-arm(s)-failed"
exit 1

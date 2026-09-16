#!/usr/bin/env bash
# freshness: added 2026-09-15 linux-yoga (order 777-k88g)
# @trace order:777-k88g, order:777-i7hf, spec:git-mirror-service
#
# test-forge-clone-wait-is-bounded.sh — the forge clone gives up, says why, and
# does not return quietly.
#
# ── WHAT THIS PINS AND WHY IT IS NOT THE LOOP LITERAL ────────────────────────
# 777-k88g's criterion 2 asks for a pin such that "an unbounded retry loop
# cannot return silently". litmus:forge-clone-reachability-probe-shape already
# greps for the loop's source line, so replacing it with a while-true would red
# there — that is a SOURCE pin and it is worth having.
#
# This fixture pins the BEHAVIOUR instead, which the source pin cannot: that
# exhausting the budget (a) terminates at all, (b) writes a FATAL naming the
# mirror, and (c) leaves a non-zero status for the lane. A loop can be bounded
# in source and still return 0 on exhaustion, and that combination — bounded,
# loud, and quietly successful — is the one no existing arm catches.
#
# ── REGIME ───────────────────────────────────────────────────────────────────
# HERMETIC and OFFLINE. The implementation under test is extracted from
# images/default/lib-common.sh with awk — the same idiom
# litmus-forge-clone-reachability-probe-shape.yaml uses on
# probe_mirror_reachable — and every external it touches is stubbed: git always
# fails, sleep is a no-op so twelve attempts cost nothing, and the mirror host
# is a fixed string. No network, no podman, no real mirror, and nothing is read
# from or written to the real checkout. No absolute timestamp appears here.
#
# ── WHY EVERY ARM RUNS IN A SUBSHELL ─────────────────────────────────────────
# The exhaustion path ends in `exit 1`, not `return 1`. Called in-process that
# would kill this fixture rather than fail an assertion, so each arm runs the
# extracted function inside ( ) and reads the subshell's status. That is also
# why (c) is worth asserting separately from (b): the FATAL text and the status
# come from different statements and a refactor can keep one without the other.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
[ -r "$LIB" ] || { echo "FAIL: lib-common not readable at $LIB"; exit 1; }

pass=0; fail=0
_ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
_bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# Extract the implementation under test, verbatim, and prove the extraction is
# not empty before any arm reads a verdict from it: an empty eval would make
# every "it terminated" assertion pass for the wrong reason.
IMPL="$(awk '/^_clone_project_from_mirror_impl\(\) \{/,/^\}/' "$LIB")"
if [ -z "$IMPL" ]; then
    echo "FAIL: PREMISE — extracted no implementation; every arm below would be vacuous"
    exit 1
fi
# The premise anchors on the FATAL the exhaustion path writes, NOT on the loop
# literal. Anchoring on the loop was the first draft and it made arm 1
# unfalsifiable: replacing the bounded loop with a while-true — the exact defect
# arm 1 exists to catch — removed the anchor, so the fixture refused to run and
# reported nothing at all instead of a red. A premise guard must not key on the
# thing the arms are trying to detect the absence of.
case "$IMPL" in
    *'FATAL: git clone failed'*) : ;;
    *) echo "FAIL: PREMISE — the extracted text has no clone-failure FATAL; the anchor moved"; exit 1 ;;
esac

# A harness that supplies every external the impl touches. $1 decides whether
# the stubbed git clone succeeds.
_harness() {
    cat <<HARNESS
set -uo pipefail
git_mirror_host() { printf 'test-mirror-host'; }
trace_lifecycle() { :; }
checkout_forge_seed_branch() { :; }
rewrite_origin_for_enclave_push() { :; }
probe_mirror_reachable() { return 0; }
export_ssh_env() { :; }
sleep() { :; }                 # twelve backoffs cost nothing
git() {
  case "\$1" in
    clone) return ${1:-1} ;;   # the knob: 1 = always fail, 0 = succeed
    *) return 0 ;;
  esac
}
TILLANDSIAS_GIT_SERVICE=1
TILLANDSIAS_PROJECT=testproj
TILLANDSIAS_GIT_MIRROR_PATH=
HARNESS
}

_run_impl() {  # $1: git-clone rc; echoes "rc=<n>" then stderr
    local gitrc="$1" out rc=0
    out="$( { bash -c "$(_harness "$gitrc")
$IMPL
_clone_project_from_mirror_impl /tmp/clone-target-\$\$" ; } 2>&1 )" || rc=$?
    printf 'rc=%s\n%s\n' "$rc" "$out"
}

# ── 1-3. EXHAUSTION: terminates, names the mirror, and is NON-ZERO ───────────
# The three are asserted separately on purpose (see the subshell note above).
res="$(timeout 60 bash -c "$(declare -f _harness _run_impl); IMPL=\$(cat); _run_impl 1" <<<"$IMPL" 2>&1)"
term_rc=$?
if [ "$term_rc" -ne 124 ]; then
    _ok "1 the clone gives up instead of retrying forever"
else
    _bad "1 the clone gives up instead of retrying forever" "still running at 60s — the wait is unbounded"
fi

rc_line="$(printf '%s' "$res" | sed -n 's/^rc=\([0-9]*\)$/\1/p' | head -1)"
if [ -n "$rc_line" ] && [ "$rc_line" != "0" ]; then
    _ok "2 exhaustion leaves a NON-ZERO status for the lane (rc=$rc_line)"
else
    _bad "2 exhaustion leaves a NON-ZERO status for the lane" "rc=${rc_line:-<none>} — a bounded loop that returns success is the silent-hang defect in a new costume"
fi

case "$res" in
    *FATAL*mirror*|*FATAL*clone*) _ok "3 exhaustion writes a FATAL naming the mirror" ;;
    *) _bad "3 exhaustion writes a FATAL naming the mirror" "no FATAL in the output" ;;
esac

# ── 4. NEGATIVE CONTROL: a clone that SUCCEEDS is not reported as failure ────
# Without this the fixture is satisfied by an implementation that always dies,
# which would pass arms 1-3 and break every forge launch.
ok_res="$(timeout 60 bash -c "$(declare -f _harness _run_impl); IMPL=\$(cat); _run_impl 0" <<<"$IMPL" 2>&1)"
ok_rc="$(printf '%s' "$ok_res" | sed -n 's/^rc=\([0-9]*\)$/\1/p' | head -1)"
case "$ok_res" in
    *FATAL*) _bad "4 NEGATIVE CONTROL: a successful clone reports no FATAL" "FATAL present on the success path" ;;
    *)       _ok "4 NEGATIVE CONTROL: a successful clone reports no FATAL" ;;
esac

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:forge-clone-wait-is-bounded:%d\n' "$pass"
    exit 0
fi
printf 'fail:forge-clone-wait-is-bounded: %d passed, %d failed\n' "$pass" "$fail"
exit 1

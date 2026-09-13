#!/usr/bin/env bash
# @trace order:1141-vf9w, spec:ci-release
#
# Fixture for lib-dispatch-reap.sh (1141-vf9w).
#
# REGIME: hermetic, offline, no podman, no toolbox, no gate. Every arm spawns
# its own marked `sleep` processes and reaps them, so it asserts nothing about
# this host and is honest on every host in the fleet. No absolute moment is
# encoded (1130-i6xj).
#
# WHY THIS FIXTURE DOES NOT RUN A GATE, and what follows for any arm that ever
# does. `./build.sh --check` SHORT-CIRCUITS on its freshness stamp: a re-run on
# an unchanged tree prints "ok:gate-fresh (stamped ...)" and exits in seconds
# WITHOUT running a gate. A stray check taken across such a run finds nothing —
# a true observation about a gate that never started, read as evidence about
# gates. That cost a real measurement on yoga 2026-09-13 and is the first thing
# anyone reproducing this defect gets wrong. ANY ARM THAT LAUNCHES A REAL GATE
# MUST PASS TILLANDSIAS_FORCE_CHECK=1, or its clean result is a stamped no-op.
# The arms below sidestep it by not needing a gate at all.
#
# The END-TO-END demonstration is deliberately NOT here — it needs a live
# toolbox and five minutes. It is the transcript recorded on 1132-r4mt: a real
# gate mid-run, the host side SIGTERMed, the container-side build.sh alive with
# a live child before the fix and reaped after it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib-dispatch-reap.sh"

pass=0; fail=0
check() { # check <label> <condition-rc>
    if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi
}

# Spawn a process carrying $1 as its token; echo its pid.
# stdio MUST be detached. A backgrounded child inherits the command
# substitution's pipe, so `pid="$(spawn_marked ...)"` blocks until that pipe
# closes — i.e. for the child's whole lifetime. The fixture hung for its full
# timeout on the first run for exactly this reason.
spawn_marked() {
    TILLANDSIAS_WRAPPER_TOKEN="$1" setsid sleep 300 >/dev/null 2>&1 </dev/null &
    echo $!
}

alive() { kill -0 "$1" 2>/dev/null; }

TOKEN_A="test-a-$$-${RANDOM}"
TOKEN_B="test-b-$$-${RANDOM}"

# 1. A minted token is unique per call — two dispatches must never share a kill
#    set, or reaping one would reap the other.
t1="$(tillandsias_dispatch_token)"; t2="$(tillandsias_dispatch_token)"
[ -n "$t1" ] && [ "$t1" != "$t2" ]; check "minted tokens are non-empty and distinct" $?

# 2. A marked process is FOUND by its token.
pa="$(spawn_marked "$TOKEN_A")"
sleep 0.3
tillandsias_marked_pids "$TOKEN_A" | grep -qxF "$pa"; check "a marked process is found by its token" $?

# 3. THE NEGATIVE CONTROL, and the reason a marker is used instead of a command
#    line at all: a process marked with a DIFFERENT token must be invisible
#    here. A stray and a healthy concurrent gate run the same argv, so a
#    reaper that matched on argv would kill a legitimate gate — a worse
#    failure than the orphan it is fixing. This arm is the only one that fails
#    for that mistake; every other arm passes with an argv matcher.
pb="$(spawn_marked "$TOKEN_B")"
sleep 0.3
if tillandsias_marked_pids "$TOKEN_A" | grep -qxF "$pb"; then false; else true; fi
check "a differently-marked process is NOT in this token's kill set" $?

# 4. The reap kills the marked tree.
tillandsias_reap_marked "$TOKEN_A" >/dev/null 2>&1
sleep 0.3
if alive "$pa"; then false; else true; fi
check "the reap kills the marked process" $?

# 5. ...and leaves the differently-marked one ALIVE. Stated separately from
#    arm 3 because "not in the kill set" and "survived the kill" are different
#    claims, and only the second one is what a concurrent gate needs.
alive "$pb"; check "the reap leaves a differently-marked process running" $?
tillandsias_reap_marked "$TOKEN_B" >/dev/null 2>&1

# 6. AN EMPTY TOKEN MATCHES NOTHING. A reaper that treated "" as a wildcard
#    would kill every process on the host the first time a token went unset.
pc="$(spawn_marked "$TOKEN_A")"
sleep 0.3
[ -z "$(tillandsias_marked_pids "")" ]; check "an empty token matches nothing" $?
tillandsias_reap_marked "$TOKEN_A" >/dev/null 2>&1

# 7. A SIGTERM-INERT PROCESS IS STILL REAPED. This is the measured case: the
#    stray ignored SIGTERM on three hosts. A reaper that sent only TERM would
#    return success here and leave the process running.
TILLANDSIAS_WRAPPER_TOKEN="$TOKEN_A" setsid bash -c 'trap "" TERM; sleep 300' \
    >/dev/null 2>&1 </dev/null &
pd=$!
sleep 0.5
tillandsias_reap_marked "$TOKEN_A" 3 >/dev/null 2>&1; reap_rc=$?
sleep 0.5
if alive "$pd"; then false; else true; fi
check "a SIGTERM-inert process is escalated to SIGKILL and reaped" $?
[ "$reap_rc" -eq 0 ]; check "the reap reports success when it did reap" $?

# 8. Reaping a token with nothing behind it is a clean no-op, not an error —
#    the normal path, since a dispatch that exited already has nothing to reap.
tillandsias_reap_marked "nonexistent-token-$$" >/dev/null 2>&1
check "reaping an absent token is a clean no-op" $?

kill -KILL "$pa" "$pb" "$pc" "$pd" 2>/dev/null || true

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: dispatch reap $pass/$total (1141-vf9w)"
    exit 0
fi
echo "FAIL: dispatch reap $pass/$total (1141-vf9w)"
exit 1

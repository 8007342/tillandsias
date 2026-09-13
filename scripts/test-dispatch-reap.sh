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

# ORDER 1141-vf9w, darwin arm (macbookair 2026-09-13).
#
# A SKIP HERE IS NOT COVERAGE, and this fixture must not be read as saying the
# reaper works on macOS. It says the opposite: the reaper CANNOT work here yet,
# so these arms would assert nothing and their red was an answer about the
# platform rather than about the code. Exit 2 is the could-not-run code the
# step's STEP_SKIP_EXIT nominates (1087-h2z9), so the gate prints a skip with a
# named reason instead of the step's content verdict.
#
# TWO INDEPENDENT DARWIN ABSENCES, both measured on tlatoanis-macbook-air
# (Apple M5, macOS 25.6.0) — either alone is enough to make the arms meaningless:
#
#   /proc     absent entirely. `ls -d /proc` -> No such file or directory, and
#             the glob `/proc/[0-9]*` does not expand, so tillandsias_marked_pids
#             finds nothing and arm 2 ("a marked process is found by its token")
#             reds. This is the one that also broke the LIBRARY.
#   setsid    absent from macOS. `spawn_marked` runs `setsid sleep 300 &`, which
#             fails immediately, so `$!` is a pid that is already dead and arm 5
#             ("the reap leaves a differently-marked process running") reds for a
#             completely different reason than arm 2 — a dead pid, not a failed
#             reap. Two causes, one verdict line, which is why reading the
#             summary count alone misleads.
#
# The condition is probed from the host at run time; no platform is named by
# uname and no version is pinned, so a darwin that grows /proc would run the
# arms rather than skip them.

pass=0; fail=0
check() { # check <label> <condition-rc>
    if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi
}

# THE SUBSTRATE-REFUSAL ARMS RUN ON EVERY HOST, AND THEY RUN BEFORE THE SKIP
# BELOW ON PURPOSE (yoga's seam, 2026-09-13). Everything after the skip needs a
# working reaper and is therefore Linux-only; these two arms need only the
# refusal path, so putting them here is what lets a LINUX host pin the behaviour
# that exists because of a DARWIN absence. Without them the unsupported arm was
# unreachable wherever anyone could have tested it: `[ -d /proc ]` is always
# true on Linux, so the guard could never be seen to fire, and a guard that
# cannot fire reads exactly like one that passes.
#
# TILLANDSIAS_DISPATCH_PROC_ROOT is a FIXTURE seam; production never sets it.
# Pointing it at an empty directory reproduces the SHAPE of the absence (no
# /proc to enumerate), not macOS itself — darwin additionally cannot read
# another process's environ at all, which is why 1145-iigx exists and why this
# arm is not a substitute for it.
_probe_root="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-reap-noproc.XXXXXX")"
rmdir "$_probe_root"   # a path that does NOT exist is the condition under test

_unsup_err="$(TILLANDSIAS_DISPATCH_PROC_ROOT="$_probe_root" \
    tillandsias_reap_marked "probe-token" 2>&1 >/dev/null)"; _unsup_rc=$?
[ "$_unsup_rc" -eq 2 ]; check "a substrate with no proc root refuses with rc 2, never a quiet 0" $?
case "$_unsup_err" in
    *unsupported:dispatch-reap:no-proc*) true ;;
    *) false ;;
esac
check "the refusal NAMES itself on stderr rather than failing silently" $?

# THE SKIP COMES AFTER THOSE ARMS, AND ONLY IF THEY PASSED. A fixture that
# skipped first would hide a genuine refusal-path regression behind "this
# platform cannot run the reaper" — the could-not-look verdict swallowing a
# real answer, which is the same confusion in the other direction. If the arms
# above failed, that is a finding about code this host CAN exercise, and it is
# reported as a failure.
if [ "$fail" -ne 0 ]; then
    echo "FAIL: dispatch reap substrate-refusal arms $pass/$((pass + fail)) (1141-vf9w)"
    exit 1
fi

if ! tillandsias_dispatch_reap_supported || ! command -v setsid >/dev/null 2>&1; then
    echo "skip:dispatch-reap:no-proc-no-setsid — this platform has no /proc and/or no setsid; the reaper is unsupported here, which is NOT the same as passing (1141-vf9w)" >&2
    exit 2
fi

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

# WAIT FOR THE PREMISE, DO NOT SLEEP AND HOPE. These arms used a fixed
# `sleep 0.3` between spawning a marked process and scanning for it, which is a
# race by construction: `/proc/<pid>/environ` is the EXEC-TIME environment, so
# between fork and exec the pid exists carrying the PARENT's environ and no
# token. The window is tiny — I could not reproduce it on yoga in 18 attempts,
# including under six spinning CPU hogs with the wait removed entirely — but
# lenovinha's gate refused an innocent diff at `FAIL: a marked process is found
# by its token`, 10/11, and the same tree standalone was 11/11 three times. A
# fixed sleep cannot be made correct by lengthening it; it can only be made
# less likely to be wrong, and it is invisible to whoever re-runs by hand.
#
# So poll until the condition the arm depends on is TRUE, and FAIL LOUDLY if it
# never becomes true rather than asserting over a premise that was never
# established — the rule this row produced, applied to the setup again.
await_marked() { # await_marked <pid> <token>; 0 if the token appears, 1 on timeout
    local pid="$1" token="$2" i marked
    for ((i = 0; i < 100; i++)); do
        # CAPTURE, THEN MATCH (1076-kft9). This read
        # `tillandsias_marked_pids ... | grep -qxF "$pid"`, and under the
        # `set -o pipefail` at the top of this file that pipeline reports
        # FAILURE ON A SUCCESSFUL MATCH: `grep -q` exits at the first hit and
        # SIGPIPEs the producer, which is still walking every /proc entry.
        #
        # MEASURED 2026-09-13, inside tillandsias-builder (where the GATE runs
        # this file), same token, same process, same library, varying only the
        # pipe:
        #     PIPED    5/5 reported FAILURE
        #     CAPTURED 0/5 reported FAILURE
        # On the host it passes either way, which is why this read as a flake:
        # it refused innocent lands and every by-hand re-run afterwards was
        # green.
        #
        # The poll below is still right — a child may genuinely not have exec'd
        # yet — but polling a pipeline that cannot report success is a loop that
        # can only time out: every one of its 100 iterations "failed" in the
        # toolbox, which is why the awaits below reported that pb and pc never
        # became visible when both were running the whole time.
        marked="$(tillandsias_marked_pids "$token" 2>/dev/null)"
        if printf '%s\n' "$marked" | grep -qxF "$pid"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

TOKEN_A="test-a-$$-${RANDOM}"
TOKEN_B="test-b-$$-${RANDOM}"

# 1. A minted token is unique per call — two dispatches must never share a kill
#    set, or reaping one would reap the other.
t1="$(tillandsias_dispatch_token)"; t2="$(tillandsias_dispatch_token)"
[ -n "$t1" ] && [ "$t1" != "$t2" ]; check "minted tokens are non-empty and distinct" $?

# 2. A marked process is FOUND by its token.
pa="$(spawn_marked "$TOKEN_A")"
await_marked "$pa" "$TOKEN_A"; check "a marked process is found by its token" $?

# 3. THE NEGATIVE CONTROL, and the reason a marker is used instead of a command
#    line at all: a process marked with a DIFFERENT token must be invisible
#    here. A stray and a healthy concurrent gate run the same argv, so a
#    reaper that matched on argv would kill a legitimate gate — a worse
#    failure than the orphan it is fixing. This arm is the only one that fails
#    for that mistake; every other arm passes with an argv matcher.
pb="$(spawn_marked "$TOKEN_B")"
# Wait for pb under its OWN token first. Without this the negative control
# passes vacuously whenever pb has not exec'd yet — "absent from A's set"
# would be satisfied by "absent from every set", which asserts nothing.
if ! await_marked "$pb" "$TOKEN_B"; then
    fail=$((fail+1)); echo "FAIL: pb never became visible under its own token — the negative control would have asserted nothing"
fi
# Same hazard, opposite assertion: a SIGPIPE-induced "failure" would make this
# arm PASS vacuously — worse than a false red, and it would survive indefinitely.
_marked_a="$(tillandsias_marked_pids "$TOKEN_A")"
if printf '%s\n' "$_marked_a" | grep -qxF "$pb"; then false; else true; fi
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
await_marked "$pc" "$TOKEN_A" || { fail=$((fail+1)); echo "FAIL: pc never became visible under its token"; }
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

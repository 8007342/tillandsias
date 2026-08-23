#!/usr/bin/env bash
# freshness: added 2026-08-23 linux-yoga (order 856-s56y)
# @trace order:856-s56y
#
# test-cycle-driver.sh — hermetic fixture for tillandsias-cycle-driver.sh.
# Exercises the two 856-s56y criterion-4 properties without launching any
# agent, systemd unit, or network call, via the driver's TILLANDSIAS_CYCLE_*
# seams:
#   1. success passthrough    (cmd true  -> rc 0, ok: verdict, JSONL rc=0)
#   2. failure passthrough    (cmd false -> rc 1, fail: verdict, JSONL rc=1 —
#                              the OUTCOME is loud while the SCHEDULE, owned by
#                              the timer, is untouched by construction)
#   3. overlap skip           (lock held -> rc 0, skip:overlap-lock-held,
#                              JSONL skipped=true — a skip is not a failure)
#   4. lock release           (after 1-3 the lock is free again; a new run fires)
# Prints PASS: cycle-driver fixture 4/4 and exits 0, or FAIL:<case> non-zero.
set -uo pipefail

DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/tillandsias-cycle-driver.sh"
FX="$(mktemp -d "${TMPDIR:-/tmp}/cycle-driver-fixture.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/root" "$FX/state"
git -C "$FX/root" init -q 2>/dev/null || true

run_driver() { # cmd -> rc; stdout captured to $FX/out
    TILLANDSIAS_CYCLE_ROOT="$FX/root" \
    TILLANDSIAS_CYCLE_STATE_DIR="$FX/state" \
    TILLANDSIAS_CYCLE_CMD="$1" \
        bash "$DRIVER" > "$FX/out" 2>/dev/null
}

fail() { echo "FAIL:$1"; exit 1; }
verdict() { tail -1 "$FX/out"; }
lastlog() { tail -1 "$FX/state/cycle-scheduler.jsonl"; }

# 1 — success passthrough
run_driver true; rc=$?
[ "$rc" -eq 0 ] || fail "success-rc:$rc"
[ "$(verdict)" = "ok:cycle-fired:rc=0" ] || fail "success-verdict:$(verdict)"
lastlog | grep -q '"rc":0,"skipped":false' || fail "success-jsonl:$(lastlog)"

# 2 — failure passthrough: loud outcome, no exception raised to the schedule
run_driver false; rc=$?
[ "$rc" -eq 1 ] || fail "failure-rc:$rc"
[ "$(verdict)" = "fail:cycle-driver:rc=1" ] || fail "failure-verdict:$(verdict)"
lastlog | grep -q '"rc":1,"skipped":false' || fail "failure-jsonl:$(lastlog)"

# 3 — overlap: a concurrent holder makes the fire a SKIP, exit 0.
# ARM-AWARE (856-s56y macOS finding): with flock(1) present the holder is a
# real flock on fd 8, exactly as before; without it (stock macOS) the holder
# is the mkdir arm's lock directory carrying THIS live pid.
LOCK="$FX/root/.git/tillandsias-cycle.lock"
[ -d "$FX/root/.git" ] || LOCK="$FX/root/tillandsias-cycle.lock"
if command -v flock >/dev/null 2>&1; then
    exec 8>"$LOCK"
    flock -n 8 || fail "fixture-cannot-take-lock"
else
    mkdir "$LOCK.d" || fail "fixture-cannot-take-lockdir"
    printf '%s\n' "$$" > "$LOCK.d/pid"
    date +%s > "$LOCK.d/epoch"
fi
run_driver true; rc=$?
[ "$rc" -eq 0 ] || fail "overlap-rc:$rc"
[ "$(verdict)" = "skip:overlap-lock-held" ] || fail "overlap-verdict:$(verdict)"
lastlog | grep -q '"skipped":true' || fail "overlap-jsonl:$(lastlog)"
if command -v flock >/dev/null 2>&1; then exec 8>&-; else rm -rf "$LOCK.d"; fi

# 4 — lock released: the next fire runs
run_driver true; rc=$?
[ "$rc" -eq 0 ] && [ "$(verdict)" = "ok:cycle-fired:rc=0" ] || fail "release:$rc:$(verdict)"

# ── The no-flock arm, exercised on EVERY host (856-s56y macOS finding) ───────
# The original unconditional `flock -n 9` skipped every fire on stock macOS
# (command-not-found read as "lock held") — silent cadence death, exit 0. A
# PATH farm that simply omits flock drives the mkdir arm on Linux exactly as
# a Mac drives it natively, per the fleet's shim-both-platforms discipline: a
# hermetic test needs the SUT to have one way of knowing.
FARM="$FX/farm"
mkdir -p "$FARM"
for t in bash sh git date mkdir cat rm uname cut tail dirname grep; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$FARM/$t"
done
run_farm() { # driver-path -> rc; stdout to $FX/out
    TILLANDSIAS_CYCLE_ROOT="$FX/root" \
    TILLANDSIAS_CYCLE_STATE_DIR="$FX/state" \
    TILLANDSIAS_CYCLE_CMD=true \
    PATH="$FARM" \
        "$FARM/bash" "${1:-$DRIVER}" > "$FX/out" 2>/dev/null
}
PATH="$FARM" "$FARM/bash" -c 'command -v flock' >/dev/null 2>&1 \
    && fail "farm-hides-flock:still-resolvable"

# 5 — no-flock success: fires, and the lock directory is released on exit
run_farm; rc=$?
[ "$rc" -eq 0 ] && [ "$(verdict)" = "ok:cycle-fired:rc=0" ] || fail "noflock-success:$rc:$(verdict)"
[ ! -d "$LOCK.d" ] || fail "noflock-lockdir-not-released"

# 6 — no-flock overlap: a LIVE holder skips
mkdir "$LOCK.d" && printf '%s\n' "$$" > "$LOCK.d/pid" && date +%s > "$LOCK.d/epoch"
run_farm; rc=$?
[ "$rc" -eq 0 ] && [ "$(verdict)" = "skip:overlap-lock-held" ] || fail "noflock-overlap:$rc:$(verdict)"

# 7 — no-flock staleness: a DEAD holder is reclaimed and the fire proceeds
printf '%s\n' 99999999 > "$LOCK.d/pid"
run_farm; rc=$?
[ "$rc" -eq 0 ] && [ "$(verdict)" = "ok:cycle-fired:rc=0" ] || fail "noflock-stale-reclaim:$rc:$(verdict)"
[ ! -d "$LOCK.d" ] || fail "noflock-stale-lockdir-not-released"

# 8 — MUTATION CONTROL: neuter the liveness test and the live-holder overlap
# scenario must go red (the mutant FIRES where the real driver skips). A sed
# that changed nothing proves nothing — cmp-verified.
sed 's/kill -0 "$_holder" 2>\/dev\/null/false/' "$DRIVER" > "$FX/driver-mutant.sh"
cmp -s "$DRIVER" "$FX/driver-mutant.sh" && fail "mutation-not-applied"
mkdir "$LOCK.d" && printf '%s\n' "$$" > "$LOCK.d/pid" && date +%s > "$LOCK.d/epoch"
run_farm "$FX/driver-mutant.sh"; rc=$?
[ "$(verdict)" = "ok:cycle-fired:rc=0" ] || fail "mutation-control-not-detected:$(verdict)"
rm -rf "$LOCK.d" 2>/dev/null || true

echo "PASS: cycle-driver fixture 8/8 (success, failure-passthrough, overlap-skip, lock-release, noflock-success, noflock-overlap, noflock-stale-reclaim, noflock-liveness-mutation-control)"

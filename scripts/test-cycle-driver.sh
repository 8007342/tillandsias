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

# 3 — overlap: a concurrent holder makes the fire a SKIP, exit 0
LOCK="$FX/root/.git/tillandsias-cycle.lock"
[ -d "$FX/root/.git" ] || LOCK="$FX/root/tillandsias-cycle.lock"
exec 8>"$LOCK"
flock -n 8 || fail "fixture-cannot-take-lock"
run_driver true; rc=$?
[ "$rc" -eq 0 ] || fail "overlap-rc:$rc"
[ "$(verdict)" = "skip:overlap-lock-held" ] || fail "overlap-verdict:$(verdict)"
lastlog | grep -q '"skipped":true' || fail "overlap-jsonl:$(lastlog)"
exec 8>&-

# 4 — lock released: the next fire runs
run_driver true; rc=$?
[ "$rc" -eq 0 ] && [ "$(verdict)" = "ok:cycle-fired:rc=0" ] || fail "release:$rc:$(verdict)"

echo "PASS: cycle-driver fixture 4/4 (success, failure-passthrough, overlap-skip, lock-release)"

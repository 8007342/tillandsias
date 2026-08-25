#!/usr/bin/env bash
# @trace order:873-zcim
# test-cycle-checkout-lock.sh — pin the 873-zcim checkout lock, BOTH ARMS.
#
# The incident: only the driver lane took the no-stacking lock, so a /loop
# fire stacked on a running driver in the same worktree. The fix is two-sided
# — prompt lanes acquire a mkdir lock the driver cannot take, and each arm
# checks the other. A one-sided test would re-create the one-sided guard.
#
# Hermetic: every scenario runs in its own scratch git repo; the driver runs
# with TILLANDSIAS_CYCLE_CMD=true (fixture seam) so nothing real fires.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Refusals must land in scratch, not the operator's real
# ~/.cache/tillandsias/overlap-refusals.jsonl — nine fixture lines polluted
# the live consumer feed before this line existed (874-w2gc). Scenario 5
# overrides this per-invocation with its own dir, which is fine.
TEST_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/checkout-lock-test-state.XXXXXX")"
export TILLANDSIAS_CYCLE_STATE_DIR="$TEST_STATE_DIR"
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

scratch() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/checkout-lock-test.XXXXXX")"
    git -C "$d" init -q -b main
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    printf '%s\n' "$d"
}

LOCKSH="$REAL_ROOT/scripts/cycle-checkout-lock.sh"
DRIVER="$REAL_ROOT/scripts/tillandsias-cycle-driver.sh"

# ── 1. acquire / refuse / release lifecycle ─────────────────────────────────
D="$(scratch)"
out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" acquire --lane a --source s1 | tail -1)"
case "$out" in ok:checkout-lock:acquired:a:$$) ok "acquire names lane and holder pid" ;; *) bad "acquire: $out" ;; esac
out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=99999999 bash "$LOCKSH" acquire --lane b --source s2 | tail -1)"
case "$out" in skip:overlap-lock-held:*pid=$$*) ok "second acquire refused, holder NAMED" ;; *) bad "second acquire: $out" ;; esac
out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=99999999 bash "$LOCKSH" release | tail -1)"
case "$out" in fail:checkout-lock:held-by-other:*) ok "release by a non-holder refused" ;; *) bad "foreign release: $out" ;; esac
out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" release | tail -1)"
case "$out" in ok:checkout-lock:released) ok "holder release succeeds" ;; *) bad "release: $out" ;; esac
rm -rf "$D"

# ── 2. stale reclaim: dead holder is reclaimed, live holder is not ──────────
D="$(scratch)"
( cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=99999999 bash "$LOCKSH" acquire --lane dead --source s >/dev/null )
out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" acquire --lane new --source s | tail -1)"
case "$out" in ok:checkout-lock:acquired:new:$$) ok "dead holder's lock is stale-reclaimed" ;; *) bad "stale reclaim: $out" ;; esac
rm -rf "$D"

# ── 3. CROSS-ARM A: prompt lane yields to a driver holding its flock ────────
if command -v flock >/dev/null 2>&1; then
    D="$(scratch)"
    GITD="$(git -C "$D" rev-parse --absolute-git-dir)"
    # Hold the driver's flock exactly as the driver does, in a background peer.
    ( exec 9>"$GITD/tillandsias-cycle.lock"; flock -n 9 && sleep 15 ) &
    FL=$!
    sleep 1
    out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" acquire --lane loop --source s | tail -1)"
    case "$out" in skip:overlap-lock-held:driver-flock) ok "prompt lane yields to a mid-cycle driver" ;; *) bad "cross-arm A: $out" ;; esac
    [ -d "$GITD/tillandsias-cycle.lock.d" ] && bad "yielding acquire left its dir behind" || ok "yielding acquire cleaned its dir"
    kill "$FL" 2>/dev/null; wait "$FL" 2>/dev/null
    rm -rf "$D"
else
    echo "skip: flock not present — cross-arm A not testable on this host"
fi

# ── 4. CROSS-ARM B: the driver skips when a prompt lane holds the dir ───────
D="$(scratch)"
( cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" acquire --lane loop --source s >/dev/null )
out="$(TILLANDSIAS_CYCLE_ROOT="$D" TILLANDSIAS_CYCLE_CMD=true TILLANDSIAS_CYCLE_STATE_DIR="$D/state" bash "$DRIVER" 2>/dev/null | tail -1)"
case "$out" in skip:overlap-lock-held) ok "driver skips when a prompt-lane cycle holds the checkout" ;; *) bad "cross-arm B: $out" ;; esac
( cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" release >/dev/null )
out="$(TILLANDSIAS_CYCLE_ROOT="$D" TILLANDSIAS_CYCLE_CMD=true TILLANDSIAS_CYCLE_STATE_DIR="$D/state" bash "$DRIVER" 2>/dev/null | tail -1)"
case "$out" in ok:cycle-fired:rc=0) ok "driver fires once the lock is released (no false lockout)" ;; *) bad "driver after release: $out" ;; esac
rm -rf "$D"

# ── 5. refusal is recorded durably OUTSIDE the checkout ─────────────────────
D="$(scratch)"; SD="$(mktemp -d)"
( cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=$$ bash "$LOCKSH" acquire --lane a --source s >/dev/null )
( cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID=99999999 TILLANDSIAS_CYCLE_STATE_DIR="$SD" bash "$LOCKSH" acquire --lane b --source rec-test >/dev/null )
if grep -q '"event":"overlap-refused".*"refused_source":"rec-test"' "$SD/overlap-refusals.jsonl" 2>/dev/null; then
    ok "refusal recorded in the external JSONL (criterion 3)"
else
    bad "no refusal record in $SD"
fi
rm -rf "$D" "$SD"

if [ "$fail" -eq 0 ]; then
    echo "ok:checkout-lock-fixture:all"
    exit 0
fi
echo "fail:checkout-lock-fixture"
exit 1

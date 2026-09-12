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


# ── 6. ORDER 1098-q7bk: the BARE invocation, which no arm above exercises. ──
# Every arm above supplies TILLANDSIAS_CYCLE_HOLDER_PID, so the line an agent
# actually types -- `bash scripts/cycle-checkout-lock.sh acquire` -- could not
# make this fixture red. The unverified fallback anchors on this script's own
# $PPID, which for an agent invocation is the tool-call wrapper shell: dead
# within seconds, so the next acquire stale-reclaims and two lanes share one
# checkout while the verdict told the caller it had acquired.
#
# `env -u CLAUDE_PID` IS MANDATORY, and is the reason this arm is not a
# one-liner. Since 1091-zh6d the script anchors on CLAUDE_PID when present
# (cycle-checkout-lock.sh anchor chain), so an arm that drops only HOLDER_PID
# is green under a claude harness and red under cron/codex/opencode -- a
# fixture whose verdict depends on who runs it. Both variables come out.
#
# A fixture has no tool-call boundary to cross, so the boundary is SIMULATED by
# a wrapper process that acquires and then exits. Without that simulation the
# defect is invisible in-process: the acquiring shell is still alive when the
# assertion runs and the lock looks healthy.
#
# THE PREDICATE IS A DISJUNCTION, and deliberately so. The packet's next_action
# asks for `status` to answer skip:overlap-lock-held:*, but that is UNREACHABLE
# under the fix this arm pins: a refusal takes no lock, so status correctly
# answers free. Only MOVING the anchor could satisfy it literally, and that is
# out of scope for a measured reason (dir_lock_live's 3h over-hold on a session
# harness, 2026-08-26). So the two acceptable outcomes are: REFUSED (the caller
# is told it does not hold the checkout), or ACQUIRED AND STILL HELD BY A LIVE
# HOLDER. `acquired` over a holder that died with the wrapper is the defect,
# and is the only failure.
bare_boundary_run() {
    # Echoes the last verdict line, then the recorded holder pid, one per line.
    local lockscript="$1"
    local dir="$2"
    local w="$dir/w.sh"
    printf '#!/usr/bin/env bash\ncd "%s" && bash "%s" acquire --lane bare --source s\n' \
        "$dir" "$lockscript" > "$w"
    env -u TILLANDSIAS_CYCLE_HOLDER_PID -u CLAUDE_PID bash "$w" 2>/dev/null | tail -1
    cat "$dir/.git/tillandsias-cycle.lock.d/pid" 2>/dev/null || true
}

D="$(scratch)"
out="$(bare_boundary_run "$LOCKSH" "$D" | sed -n 1p)"
held="$(cat "$D/.git/tillandsias-cycle.lock.d/pid" 2>/dev/null || true)"
case "$out" in
    refused:checkout-lock:no-holder-pid)
        ok "bare acquire refuses instead of anchoring to a pid that dies with the tool call" ;;
    ok:checkout-lock:acquired:*|warn:checkout-lock:acquired-unverified-anchor:*)
        if [ -n "$held" ] && kill -0 "$held" 2>/dev/null; then
            ok "bare acquire produced a lock whose holder survived the boundary"
        else
            bad "bare acquire returned '$out' but holder ${held:-<none>} is already dead -- the next acquire stale-reclaims: two lanes, one checkout"
        fi ;;
    *) bad "bare acquire: unexpected verdict: $out" ;;
esac

# ── 7. MUTATION CONTROL for arm 6: the PRE-1098-q7bk script must FAIL it. ────
# Arm 6 passes trivially once the refusal is present, so this arm strips the
# refusal back out of a scratch copy and re-runs arm 6's exact scenario against
# the mutant, proving arm 6 has teeth rather than passing by luck. Same shape
# as the mutation arms in scripts/test-check-credential-channel.sh (876-exg2 /
# 877-mynm).
#
# NOTE THE INVERTED POLARITY. 876-exg2's mutant fails LOUDLY, so its arm can
# assert on a verdict string. This defect fails QUIETLY: the mutant prints
# warn:...acquired-unverified-anchor -- a verdict that reads like a caveat, not
# a failure -- and the lock is gone anyway. So the assertion here is not on the
# verdict but on the HOLDER BEING DEAD once the wrapper exits, which is exactly
# arm 6's own predicate. The two arms share one predicate, so this really does
# measure the thing arm 6 measures.
MUT="$(scratch)/pre-1098-lock.sh"
awk '/# ORDER 1098-q7bk — REFUSE an UNVERIFIED anchor/{skip=1}
     skip && /^        # 1\. The atomic claim among prompt lanes\./{skip=0}
     skip{next} {print}' "$LOCKSH" > "$MUT"
if grep -q 'refused:checkout-lock:no-holder-pid' "$MUT"; then
    bad "MUTATION: the strip left the refusal in place -- the awk terminator drifted; arm 7 proves nothing"
elif ! grep -q 'The atomic claim among prompt lanes' "$MUT"; then
    bad "MUTATION: the strip removed too much -- the acquire body is gone; arm 7 proves nothing"
elif ! bash -n "$MUT" 2>/dev/null; then
    bad "MUTATION: the stripped script does not parse; arm 7 proves nothing"
else
    MD="$(scratch)"
    mout="$(bare_boundary_run "$MUT" "$MD" | sed -n 1p)"
    mheld="$(cat "$MD/.git/tillandsias-cycle.lock.d/pid" 2>/dev/null || true)"
    case "$mout" in
        refused:checkout-lock:no-holder-pid)
            bad "MUTATION: the pre-fix script still refused -- the refusal is not what arm 6 measures" ;;
        ok:checkout-lock:acquired:*|warn:checkout-lock:acquired-unverified-anchor:*)
            if [ -n "$mheld" ] && kill -0 "$mheld" 2>/dev/null; then
                bad "MUTATION: the pre-fix script acquired with a LIVE holder $mheld -- arm 6 would pass against the mutant, so it has no teeth"
            else
                ok "MUTATION: the pre-fix script acquires over dead holder ${mheld:-<none>} -- arm 6 is red without the fix (pre-fix result: FAILS)"
            fi ;;
        *) bad "MUTATION: unexpected verdict from the pre-fix script: $mout" ;;
    esac
    rm -rf "$MD"
fi
rm -rf "$D"

if [ "$fail" -eq 0 ]; then
    echo "ok:checkout-lock-fixture:all"
    exit 0
fi
echo "fail:checkout-lock-fixture"
exit 1

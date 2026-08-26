#!/usr/bin/env bash
# @trace order:899-q9di
#
# test-cycle-lock-attested-release.sh — a cycle that attests must not refuse the
# checkout to its own successor.
#
# WHAT THIS PINS, and why the negative controls are the load-bearing half.
#
# Finalization step 9 states four times that the MO-FULL marker is the cycle's
# FINAL OUTPUT LINE; step 9b then asks for a lock release AFTER it. Both cannot
# be obeyed, and an agent that obeys the more emphatic one strands the lock.
# MEASURED on macuahuitl 2026-08-26T03:38Z: the hourly fire was refused
# `skip:overlap-lock-held` by pid 2393229 — its own $PPID, a live `claude`
# 07:56:39 old that had emitted a valid MO-FULL an hour earlier. On a host whose
# harness spans many cycles the "dead holder" escape never fires, so the refusal
# lasts the full 3h stale bound: up to three skipped fires on an hourly loop.
#
# The fix marks the lock attested from `mo-full-attest.sh record` — the one step
# that runs EXACTLY ONCE per cycle. `self` was rejected as the hook because it is
# callable any number of times mid-cycle, and releasing on it would free the
# checkout while work continues.
#
# Cases 2 and 4 are why this file is longer than the fix. The naive version of
# this change — "reclaim a lock whose holder already attested" — is one careless
# edit away from "reclaim a lock", which would retire 873-zcim's entire purpose
# while every positive case still passed. Case 2 fails if an UNATTESTED live
# holder is ever reclaimed; case 4 fails if `mark-attested` will mark a lock it
# does not own. Neither can be satisfied by weakening the lock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the falsification check is REPRODUCIBLE rather than a claim.
# Case 1 must FAIL against the pre-fix script, or this file proves nothing:
#   git show <pre-fix-sha>:scripts/cycle-checkout-lock.sh > /tmp/old.sh
#   TILLANDSIAS_LOCK_SCRIPT=/tmp/old.sh bash scripts/test-cycle-lock-attested-release.sh
# Verified 2026-08-26 at cc1d5fc44: case 1 fails, cases 2/3/5 pass, case 4 is
# absent (mark-attested is an unknown command there). A fixture whose positive
# case passes against the unfixed code is asserting nothing — measured that
# exact vacuity in a different fixture earlier the same night.
LOCKSH="${TILLANDSIAS_LOCK_SCRIPT:-$ROOT/scripts/cycle-checkout-lock.sh}"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=1; }

WORK="$(mktemp -d)"
# A long-lived stand-in for the agent harness: a real live pid we can point the
# lock at, that is NOT an ancestor of this test.
sleep 600 &
OTHER_PID=$!
cleanup() { kill "$OTHER_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
git init -q "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
cp "$LOCKSH" "$REPO/scripts/cycle-checkout-lock.sh"
chmod +x "$REPO/scripts/cycle-checkout-lock.sh"
: > "$REPO/seed"; git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
GD="$(git -C "$REPO" rev-parse --absolute-git-dir)"
LOCKD="$GD/tillandsias-cycle.lock.d"

lock_as() {  # lock_as <pid> [attested]
    rm -rf "$LOCKD"; mkdir -p "$LOCKD"
    printf '%s\n' "$1" > "$LOCKD/pid"
    date +%s > "$LOCKD/epoch"
    printf 'loop-cron\n' > "$LOCKD/lane"
    printf 'fixture\n' > "$LOCKD/source"
    [ "${2:-}" = "attested" ] && date +%s > "$LOCKD/attested"
    return 0
}
run() { ( cd "$REPO" && TILLANDSIAS_CYCLE_STATE_DIR="$WORK/state" \
          TILLANDSIAS_CYCLE_HOLDER_PID="$1" ./scripts/cycle-checkout-lock.sh "${@:2}" 2>&1 ); }

# ── 0. THE PRIMITIVE ITSELF, tested directly and FIRST ─────────────────────
# Every arm below rides on ancestry resolution, so if the ppid mechanism does
# not work on this host they all fail with ownership verdicts that say nothing
# about the real cause. That is not hypothetical: the first version of this
# guard used `ps -o ppid=`, which MSYS does not implement, and landed RED on
# windows while green on linux and darwin — surfacing as
# `fail:checkout-lock:held-by-other` about the caller's OWN lock, with the
# underlying "unknown option -- o" swallowed by a 2>/dev/null.
#
# Found by yolanda within minutes of the merge, on the one lane that could see
# it. This arm exists so the NEXT such defect is reported as "the probe does not
# work here" instead of as a wrong answer about lock ownership.
out="$(run "$$" ppid-probe --pid "$$")"
case "$out" in
    ok:ppid-probe:*)
        # Cross-check against a second, independent mechanism where one exists,
        # so a probe that returns a confident WRONG number is caught too.
        got="${out#ok:ppid-probe:}"
        truth=""
        [ -r "/proc/$$/stat" ] && truth="$(awk '{print $4}' "/proc/$$/stat" 2>/dev/null)"
        [ -n "$truth" ] || truth="$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')"
        if [ -z "$truth" ]; then
            ok "ppid probe resolves ($got); no independent mechanism here to cross-check against"
        elif [ "$got" = "$truth" ]; then
            ok "ppid probe resolves and agrees with an independent mechanism ($got)"
        else
            bad "ppid probe returned $got but an independent mechanism says $truth"
        fi ;;
    *) bad "ppid probe has no working mechanism on this host: $out" ;;
esac

# ── 1. THE DEFECT: an attested holder must not refuse its own successor ──────
# Pre-fix this returns skip:overlap-lock-held — the live-pid test passes and
# nothing else is consulted. This case is the reproduction of the measured bug.
lock_as "$OTHER_PID" attested
out="$(run "$$" acquire --lane loop-cron --source fixture)"
case "$out" in
    ok:checkout-lock:acquired:*) ok "an ATTESTED holder's lock is reclaimed by the next cycle" ;;
    *) bad "attested lock was not reclaimed: $out" ;;
esac

# ── 2. NEGATIVE CONTROL: an UNATTESTED live holder still wins ───────────────
# If this ever passes acquisition, 873-zcim is gone and every positive case in
# this file would still be green. This is the case that must never be relaxed.
lock_as "$OTHER_PID"
out="$(run "$$" acquire --lane loop-cron --source fixture)"
case "$out" in
    skip:overlap-lock-held:*) ok "an UNATTESTED live holder still refuses (873-zcim preserved)" ;;
    *) bad "concurrent live holder was not refused: $out" ;;
esac

# ── 3. mark-attested works from a DESCENDANT of the holder ─────────────────
# `record` runs below the harness the lock names, so ownership is ancestry, not
# equality. An equality test would refuse to mark every lock it exists to mark.
lock_as "$$"
out="$(run 999999 mark-attested)"
case "$out" in
    ok:checkout-lock:marked-attested)
        [ -f "$LOCKD/attested" ] \
            && ok "mark-attested accepts a descendant of the holder and writes the marker" \
            || bad "reported marked but wrote no marker file" ;;
    *) bad "mark-attested refused its own holder: $out" ;;
esac

# ── 4. NEGATIVE CONTROL: mark-attested refuses a lock it does not own ───────
# Marking another agent's in-flight cycle "done" would hand their checkout away,
# which is the exact failure the lock exists to prevent.
lock_as "$OTHER_PID"
out="$(run "$$" mark-attested)"
case "$out" in
    fail:checkout-lock:held-by-other:*)
        [ -f "$LOCKD/attested" ] \
            && bad "refused but wrote the marker anyway" \
            || ok "mark-attested refuses a lock held by an unrelated live pid" ;;
    *) bad "marked a lock held by an unrelated live pid: $out" ;;
esac

# ── 5. mark-attested with no lock is a no-op, not an error ─────────────────
# record() calls this best-effort on every cycle, including lanes that took no
# lock at all; it must not turn a clean attestation into a failure.
rm -rf "$LOCKD"
out="$(run "$$" mark-attested)"
case "$out" in
    ok:checkout-lock:no-lock-held) ok "mark-attested with no lock is a clean no-op" ;;
    *) bad "no-lock mark-attested did not report cleanly: $out" ;;
esac

echo "cycle-lock-attested-release: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:cycle-lock-attested-release-fixture:$pass"

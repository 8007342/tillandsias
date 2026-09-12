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
    ok:checkout-lock:acquired:*|warn:checkout-lock:acquired-dead-anchor:*)
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
        ok:checkout-lock:acquired:*|warn:checkout-lock:acquired-dead-anchor:*)
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

# ── 8. WINDOWS LIVENESS: `kill -0` cannot see a native pid; pid_is_live must. ─
#
# REGIME: msys-only, live-process, in-checkout-scratch. Arms 1-7 all anchor on
# `$$` or on 99999999 — an MSYS pid and a nonexistent one — and BOTH of those
# `kill -0` answers correctly under MSYS. That is precisely why this fixture
# was green on yolanda while the guard it pins was inert there: the one pid
# shape the probe could not see, a NATIVE Windows pid, appeared in no arm. The
# anchor a claude harness exports (CLAUDE_PID) is exactly that shape.
#
# The live pid here comes from `ps`, whose WINPID column is a DIFFERENT
# mechanism from the `tasklist` the fix uses, so this arm cross-checks the
# probe rather than asking it to confirm itself. The two pids name ONE process,
# which is what makes arm 8b a measurement and not a guess.
#
# Off Windows the arm skips loudly: there is no second pid space, so there is
# nothing here to measure and a silent pass would misreport that.
winpid_of() {  # $1 = msys pid -> its native WINPID. A LOOKUP, not a liveness
    # claim: nothing but `ps` links the two pid spaces, so the translation has
    # to come from here even though the fix also reads `ps -W`.
    ps 2>/dev/null | awk -v p="$1" '$1==p {print $4; exit}'
}
native_pid_live_oracle() {  # $1 = native WINPID -> 0 if running, INDEPENDENTLY
    # of pid_is_live's own mechanism. This is the whole reason the fix uses
    # `ps -W` and this uses `tasklist`: an arm that asked `ps -W` whether `ps -W`
    # was right would be a tautology wearing a test's clothes.
    #
    # /FO CSV, not the default table. The table form is space-padded columns
    # (image, pid, session name, SESSION NUMBER, memory) and a whitespace match
    # for the pid also hits the session-number column -- pid 1 reads live on
    # every host. CSV quotes each field, so field 2 can be matched exactly.
    MSYS_NO_PATHCONV=1 tasklist /NH /FO CSV /FI "PID eq $1" 2>/dev/null \
        | grep -q "^\"[^\"]*\",\"$1\","
}
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        sleep 40 &
        MP=$!
        sleep 1
        WP="$(winpid_of "$MP")"
        if [ -z "$WP" ] || [ "$WP" = "$MP" ]; then
            bad "arm 8: ps gave no distinct WINPID for $MP (got '${WP:-<none>}') — the cross-check source is gone, so this arm proves nothing"
        else
            # (a) The pre-existing primitive, stated as a measurement: it is
            #     right about the MSYS pid and wrong about the native one.
            #     Both name the SAME running process.
            if kill -0 "$MP" 2>/dev/null; then
                ok "arm 8a: kill -0 resolves the MSYS pid $MP (why arms 1-7 are green here)"
            else
                bad "arm 8a: kill -0 could not see MSYS pid $MP — the fixture's own premise is broken"
            fi
            if kill -0 "$WP" 2>/dev/null; then
                echo "skip: arm 8b — kill -0 resolved native pid $WP on this host, so the two pid spaces are not distinct here; the defect this arm pins cannot occur"
            else
                ok "arm 8b: kill -0 calls native pid $WP dead while it is running (the defect's cause)"
            fi
            # (b) INDEPENDENT ATTESTATION that the native pid really is
            #     running, from a mechanism pid_is_live does not use. Without
            #     this the arm rests on `ps` twice and proves nothing.
            if native_pid_live_oracle "$WP"; then
                ok "arm 8c-pre: tasklist independently confirms native pid $WP is running"
            else
                bad "arm 8c-pre: tasklist cannot see native pid $WP — the oracle disagrees with ps, so arms 8c/8e/8f rest on one unconfirmed mechanism"
            fi
            # (c) The primitive under test must get BOTH right.
            out="$(bash "$LOCKSH" pid-probe --pid "$WP" | tail -1)"
            case "$out" in
                ok:pid-probe:live:"$WP":*) ok "arm 8c: pid-probe sees the live native pid $WP" ;;
                *) bad "arm 8c: pid-probe on live native pid $WP: $out" ;;
            esac
            out="$(bash "$LOCKSH" pid-probe --pid 99999999 | tail -1)"
            case "$out" in
                ok:pid-probe:dead:99999999:*) ok "arm 8d: pid-probe still calls a nonexistent pid dead (no blanket-live regression)" ;;
                *) bad "arm 8d: pid-probe on a dead pid: $out" ;;
            esac
            # PID 1 IS THE REGRESSION THIS ARM EXISTS TO CATCH, not a
            # decorative negative. Git Bash reports PPID=1 to a tool shell
            # (esme, 2026-09-12), so section 1b's explicit recipe
            # TILLANDSIAS_CYCLE_HOLDER_PID=$PPID anchors here on pid 1 — making
            # it the pid this probe is MOST likely to be asked about on Windows.
            # A `tasklist` table-form probe calls it live (it matches the
            # session-number column) and would hand every such cycle a
            # confident "acquired" over an anchor that is not a process.
            out="$(bash "$LOCKSH" pid-probe --pid 1 | tail -1)"
            case "$out" in
                ok:pid-probe:dead:1:*) ok "arm 8d2: pid 1 — what \$PPID resolves to under Git Bash — reads dead, not live" ;;
                *) bad "arm 8d2: pid-probe on pid 1: $out (a probe that calls pid 1 live makes the 1b recipe silently 'work')" ;;
            esac
            # (d) THE SYMPTOM, at lock level: this is what actually cost both
            #     Windows hosts their mutual exclusion. Acquire on a live
            #     native anchor, then read the lock the way a sibling lane
            #     does. `free` here means two lanes, one checkout.
            D="$(scratch)"
            out="$(cd "$D" && TILLANDSIAS_CYCLE_HOLDER_PID="$WP" bash "$LOCKSH" acquire --lane nat --source s 2>/dev/null | tail -1)"
            case "$out" in
                ok:checkout-lock:acquired:nat:"$WP") ok "arm 8e: acquire on a live native anchor is clean, not warn:...-dead-anchor" ;;
                *) bad "arm 8e: acquire on live native anchor $WP: $out" ;;
            esac
            out="$(cd "$D" && env -u TILLANDSIAS_CYCLE_HOLDER_PID -u CLAUDE_PID bash "$LOCKSH" status | tail -1)"
            case "$out" in
                skip:overlap-lock-held:*pid=$WP*) ok "arm 8f: a sibling lane is refused — the lock is real on Windows" ;;
                ok:checkout-lock:free) bad "arm 8f: sibling lane reads FREE while native holder $WP is alive — the guard is inert on this host" ;;
                *) bad "arm 8f: sibling status: $out" ;;
            esac
            rm -rf "$D"
        fi
        kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null
        ;;
    *)
        echo "skip: arms 8-9 are msys-only — one pid space on $(uname -s 2>/dev/null), so kill -0 is a sufficient liveness probe here"
        ;;
esac

# ── 9. MUTATION CONTROL for arm 8: the pre-fix probe must FAIL it. ───────────
#
# REGIME: msys-only, live-process, scratch-copy-of-the-script-under-test.
# Arm 8 passes trivially once the MSYS branch exists, so this arm strips that
# branch back out and re-runs arm 8's own predicates against the mutant. Same
# shape as arm 7, and it shares arm 7's inverted polarity: the mutant does not
# fail loudly, it reports `dead` and `free` — verdicts that read like data.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        sleep 40 &
        MP=$!
        sleep 1
        WP="$(winpid_of "$MP")"
        MUT="$(scratch)/pre-winpid-lock.sh"
        awk 'stripped!=1 && $0=="        MINGW*|MSYS*|CYGWIN*)" {skip=1}
             skip && $0=="    esac" {skip=0; stripped=1}
             skip{next} {print}' "$LOCKSH" > "$MUT"
        if [ -z "$WP" ] || [ "$WP" = "$MP" ]; then
            bad "arm 9: no distinct WINPID — cannot run the control"
        elif grep -q 'ps -W 2>/dev/null | awk' "$MUT"; then
            bad "MUTATION: the strip left the tasklist branch in place — the awk terminator drifted; arm 9 proves nothing"
        elif ! grep -q 'pid_is_live()' "$MUT"; then
            bad "MUTATION: the strip removed too much — pid_is_live is gone; arm 9 proves nothing"
        elif ! bash -n "$MUT" 2>/dev/null; then
            bad "MUTATION: the stripped script does not parse; arm 9 proves nothing"
        elif kill -0 "$WP" 2>/dev/null; then
            echo "skip: arm 9 — kill -0 resolves native pid $WP here, so the mutant is not actually degraded on this host"
        else
            mout="$(bash "$MUT" pid-probe --pid "$WP" | tail -1)"
            case "$mout" in
                ok:pid-probe:dead:"$WP":*) ok "MUTATION: the pre-fix probe calls live native pid $WP dead — arm 8c is red without the fix (pre-fix result: FAILS)" ;;
                ok:pid-probe:live:*) bad "MUTATION: the pre-fix probe still saw $WP — arm 8c would pass against the mutant, so it has no teeth" ;;
                *) bad "MUTATION: unexpected pid-probe verdict from the pre-fix script: $mout" ;;
            esac
            MD="$(scratch)"
            ( cd "$MD" && TILLANDSIAS_CYCLE_HOLDER_PID="$WP" bash "$MUT" acquire --lane nat --source s >/dev/null 2>&1 )
            mout="$(cd "$MD" && env -u TILLANDSIAS_CYCLE_HOLDER_PID -u CLAUDE_PID bash "$MUT" status | tail -1)"
            case "$mout" in
                ok:checkout-lock:free) ok "MUTATION: the pre-fix script leaves the checkout readable as FREE under a live native holder — arm 8f is red without the fix (pre-fix result: FAILS)" ;;
                skip:overlap-lock-held:*) bad "MUTATION: the pre-fix script still refused the sibling lane — arm 8f would pass against the mutant, so it has no teeth" ;;
                *) bad "MUTATION: unexpected status from the pre-fix script: $mout" ;;
            esac
            rm -rf "$MD"
        fi
        kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null
        ;;
esac

if [ "$fail" -eq 0 ]; then
    echo "ok:checkout-lock-fixture:all"
    exit 0
fi
echo "fail:checkout-lock-fixture"
exit 1

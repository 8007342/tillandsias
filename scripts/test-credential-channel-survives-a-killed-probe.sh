#!/usr/bin/env bash
# @trace spec:ci-release, plan 1347-r9g8
#
# test-credential-channel-survives-a-killed-probe.sh
#
# THE QUESTION. Every probe in check-credential-channel.sh reaches something
# that can die while being read: gnome-keyring-daemon aborts inside its own
# D-Bus property handler (1265-8qr6, five SIGABRTs on lenovinha in one day), a
# session bus goes away with the session, `gh` blocks on a locked keyring until
# something kills it. The guard's verdict is a PRECONDITION for committable work
# across the fleet, so the question is not whether the probe can die — it can —
# but whether the guard still ANSWERS when it does.
#
# WHY A SILENT GUARD IS THE WORST OUTCOME, worse than a wrong verdict. Consumers
# grep the verdict string. A guard that hangs produces no string; a guard that
# dies mid-write produces a partial one; a guard that emits two produces an
# ambiguous one. All three read downstream as "not blocked" — the dispatch
# preflight triggers on `blocked:*` — so a probe death becomes a silent green on
# a host with no credential channel. That is the 1092-uv3k shape: an arm that
# verifies nothing sailing through as health.
#
# ARM 4 IS THE ONE macuahuitl ASKED FOR and is a control on the SUITE, not the
# guard: every verdict must grep to exactly ONE emitting line, and adding a
# second emitter must MOVE THE COUNT. Without that second half, "the count is 1"
# is a number that cannot be shown to respond to anything — and this session
# already produced a count of 11 for a verdict that had 3, by counting comments.
#
# Usage: scripts/test-credential-channel-survives-a-killed-probe.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

GUARD="scripts/check-credential-channel.sh"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

[ -f "$GUARD" ] || { echo "FAIL: $GUARD absent"; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/killed-probe.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

# One grammar line, and ONLY one. Anchored at the start so a diagnostic
# sentence that happens to contain a verdict word is not counted as a verdict.
_verdict_lines() {
    grep -cE '^(ok|unverified|blocked|missing|unknown):[a-z0-9:-]+$' "$1" 2>/dev/null || echo 0
}

# BOUND PORTABLY OR SAY SO. `timeout` is GNU coreutils and is ABSENT on a stock
# macOS; there it ships as `gtimeout` via brew, or not at all. A bare
# `timeout 90` here is the exact shape 1302-7j8p's guard exists to stop: step
# 416 pinned sha256sum under a restricted PATH, was green on its author's
# regime, and refused a genuine artifact on macbookair. This fixture is a GATE
# STEP, so it runs on every host, and a Linux-only bound would red the macOS
# gate for a reason that has nothing to do with the credential guard.
#
# It is not caught by check-portability-idioms.sh, which scans sed -i and
# friends but not `timeout` — verified, not assumed, so this comment is the only
# thing standing between the next author and the same break.
#
# WHEN NEITHER EXISTS the arms that need a bound are SKIPPED BY NAME rather than
# run unbounded. Arms 1 and 3 hang the probe DELIBERATELY; running them without
# a bound does not degrade the measurement, it wedges the gate. A named skip is
# could-not-run; an unbounded run is a hang reported as nothing.
_BOUND=""
if command -v timeout >/dev/null 2>&1; then _BOUND="timeout"
elif command -v gtimeout >/dev/null 2>&1; then _BOUND="gtimeout"
fi

_run_guard() {  # $1=bindir  -> stdout file $W/.out, rc in $W/.rc
    local bindir="$1"
    if [ -n "$_BOUND" ]; then
        env -u TILLANDSIAS_HOST_KIND PATH="$bindir:$PATH" \
            "$_BOUND" 90 bash "$GUARD" >"$W/.out" 2>"$W/.err"
    else
        env -u TILLANDSIAS_HOST_KIND PATH="$bindir:$PATH" \
            bash "$GUARD" >"$W/.out" 2>"$W/.err"
    fi
    echo $? >"$W/.rc"
}

echo "credential-channel survives a killed probe"

# ── ARM 1: the bus never answers. ───────────────────────────────────────────
# A busctl that hangs forever is the session-bus-went-away shape. The guard
# bounds this read (_ccc_timeout 5); if that bound is ever removed, this arm
# hangs until the 90s outer timeout and fails on elapsed time.
echo "arm 1 — a HANGING busctl must not hang the guard"
if [ -z "$_BOUND" ]; then
    echo "  skip:no-timeout-tool — this arm HANGS the probe on purpose and needs timeout(1)/gtimeout(1) to bound it; running it unbounded would wedge the gate, not measure it"
else
mkdir -p "$W/b1"
printf '#!/usr/bin/env bash\nsleep 3600\n' > "$W/b1/busctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/b1/gh"
chmod +x "$W/b1/busctl" "$W/b1/gh"
t0=$(date +%s); _run_guard "$W/b1"; t1=$(date +%s)
elapsed=$((t1 - t0))
if [ "$elapsed" -lt 60 ]; then
    ok "guard answered in ${elapsed}s (bounded, not wedged)"
else
    bad "guard took ${elapsed}s — a probe bound was removed"
fi
n="$(_verdict_lines "$W/.out")"
if [ "$n" -eq 1 ]; then ok "exactly one verdict line"; else bad "expected 1 verdict, got $n: $(cat "$W/.out")"; fi
fi

# ── ARM 2: the probe is KILLED mid-read. ────────────────────────────────────
# Not a clean non-zero exit: killed by a signal, which is how the 1265-8qr6
# abort actually presents (rc 134/137, and the daemon is gone afterwards). A
# guard that only handles clean failure treats this as something else.
echo "arm 2 — a busctl KILLED by a signal must not become a verdict about the credential"
# THE gh STUB HERE MUST NOT ANSWER FOR THE GUARD, and the first version of this
# arm got that wrong in a way worth recording. It stubbed `gh` to exit 0 for
# every query, so gh was actively asserting "credentials fine" -- the guard then
# verified a push channel and correctly answered `ok:`, and this arm reported
# "the guard read a corpse as health". The guard was right and the FIXTURE was
# lying. An arm about a dead secret-service probe must leave the secret-service
# probe as the only thing speaking.
mkdir -p "$W/b2"
printf '#!/usr/bin/env bash\nkill -9 $$\n' > "$W/b2/busctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/b2/gh"
chmod +x "$W/b2/busctl" "$W/b2/gh"
_run_guard "$W/b2"
n="$(_verdict_lines "$W/.out")"
if [ "$n" -eq 1 ]; then ok "exactly one verdict line after a signal-killed probe"; else bad "expected 1 verdict, got $n: $(cat "$W/.out")"; fi
# THE LOAD-BEARING ASSERTION, and the defect it caught on its first run.
# A probe that DIED means the guard COULD NOT ASK. Answering
# `missing:no-credential-channel` asserts the credential is ABSENT and invites
# `gh auth login`, which evicts the fleet (1025-a896) -- the 1189-2ra5
# conflation, at the exact site 1347-r9g8 exists to remove. Before the fix this
# read `missing:`; refusing to claim the channel EXISTS never licensed claiming
# it is ABSENT.
if grep -qE '^missing:' "$W/.out"; then
    bad "a DEAD probe produced missing: — 'could not ask' became 'you have no credential' ($(cat "$W/.out"))"
else
    ok "a dead probe did not report the credential as missing ($(cat "$W/.out" | tr -d '\n'))"
fi
# THE PRECISE STRING IS ASSERTED ONLY WHERE THE DISTINCTION IS OBSERVABLE, and
# this is a real finding rather than a convenience — surfaced by running this
# fixture on a PATH with no timeout(1)/gtimeout(1).
#
# The state reader classifies a probe as "never answered" from its exit status:
# rc 124 (timeout killed it) or rc >= 128 (died on a signal). Both of those
# require the probe to have actually RUN under a bounding tool. With no such
# tool, `_ccc_timeout` refuses to run the probe at all (order 988: it will not
# run one unbounded), so the SIGKILL never happens and its status never exists.
# The reader then sees an ordinary non-zero, classifies not-serving, and answers
# blocked:credential-unretrievable-no-keyring-service instead of
# unknown:secret-service-unprobed.
#
# Both are refusals and neither evicts the fleet, so this is not a safety hole —
# but it is the order's own distinction collapsing on a host that cannot bound a
# probe, and it is worth stating rather than hiding behind a skip. Filed for
# 1347-r9g8 rather than fixed here: teaching the reader to answer `unknown` when
# it could not bound the probe is a guard change, and a guard change does not
# belong in a fixture commit.
#
# So the PROPERTY is asserted everywhere (a dead probe never reports the
# credential MISSING — the assertion above) and the exact string only where a
# bounding tool makes the kill observable.
if [ -z "$_BOUND" ]; then
    echo "  skip:no-timeout-tool — a killed probe cannot be distinguished from an answered one without a bounding tool; the not-missing property above still held"
elif grep -qE '^(ok|unverified):(gh-credentials-store|gh-token-env|github-token-env)$' "$W/.out"; then
    # THE ARM'S SECOND UNASSERTED PREMISE, measured on yoga 2026-09-22.
    # <git-dir>/.gh-credentials is the guard's HIGHEST-precedence channel, so on
    # a checkout that has one the guard answers about the store and never
    # reaches the secret-service probe -- the kill is real and simply not
    # observable in the verdict. This arm read that correct answer as a failure:
    # 10/11 on the main checkout, 11/11 in a linked worktree of the SAME commit
    # minutes apart, because a worktree's git-dir is .git/worktrees/<name> and
    # carries no store file. Same host, same fixture, same subject, opposite
    # verdicts -- which is the shape that gets read as flake.
    #
    # Skipped BY NAME rather than made to pass, for the same reason the _BOUND
    # branch above is: teaching the guard to ignore a channel it legitimately
    # found would be a guard change, and the not-missing property above -- the
    # load-bearing one -- still holds here and is still asserted.
    echo "  skip:higher-precedence-channel:$(tr -d '\n' < "$W/.out") — a credential channel outranking the secret-service probe answered first, so a killed probe cannot change this verdict; the not-missing property above still held"
elif grep -qE '^unknown:secret-service-unprobed$' "$W/.out"; then
    ok "it names the state precisely: unprobed, not absent"
else
    bad "expected unknown:secret-service-unprobed, got: $(cat "$W/.out")"
fi

# ── ARM 3: gh blocks forever. ──────────────────────────────────────────────
# The 1189-2ra5 shape. With the store serving (busctl answers), the guard is
# allowed to ask gh — and must still bound it.
echo "arm 3 — a HANGING gh must not hang the guard"
if [ -z "$_BOUND" ]; then
    echo "  skip:no-timeout-tool — as arm 1: this arm hangs gh on purpose and needs a bounding tool"
else
mkdir -p "$W/b3"
printf '#!/usr/bin/env bash\necho "NAME PID"\necho "org.freedesktop.secrets 1 gnome-keyring"\nexit 0\n' > "$W/b3/busctl"
printf '#!/usr/bin/env bash\nsleep 3600\n' > "$W/b3/gh"
chmod +x "$W/b3/busctl" "$W/b3/gh"
t0=$(date +%s); _run_guard "$W/b3"; t1=$(date +%s)
elapsed=$((t1 - t0))
if [ "$elapsed" -lt 80 ]; then
    ok "guard answered in ${elapsed}s with gh hung"
else
    bad "guard took ${elapsed}s — the gh probe bound is gone"
fi
n="$(_verdict_lines "$W/.out")"
if [ "$n" -eq 1 ]; then ok "exactly one verdict line"; else bad "expected 1 verdict, got $n: $(cat "$W/.out")"; fi
fi

# ── ARM 4: THE SECOND-EMITTER CONTROL. ─────────────────────────────────────
# Count EMITTING lines per verdict, then prove the count can move.
#
# The count alone is inert: "1" is indistinguishable from "my regex matches
# nothing". So each verdict is counted, then a second emitter is injected into a
# COPY of the guard and the same counter must read 2. A counter that cannot be
# made to say 2 was never measuring emitters.
echo "arm 4 — one emitter per verdict, and the counter can move"
_emitters() {  # $1=file $2=verdict
    grep -cE "^[[:space:]]*echo \"$2\"" "$1" 2>/dev/null || echo 0
}
for verdict in "missing:no-credential-channel" "unknown:secret-service-unprobed"; do
    n="$(_emitters "$GUARD" "$verdict")"
    if [ "$n" -eq 1 ]; then
        ok "$verdict has exactly 1 emitting line"
    else
        bad "$verdict has $n emitting lines (expected 1)"
    fi
    # THE CONTROL.
    cp "$GUARD" "$W/injected.sh"
    printf '\n_ccc_never_called_second_emitter() {\n  echo "%s"\n}\n' "$verdict" >> "$W/injected.sh"
    m="$(_emitters "$W/injected.sh" "$verdict")"
    if [ "$m" -eq 2 ]; then
        ok "$verdict: injecting a second emitter moved the count 1 -> 2"
    else
        bad "$verdict: counter did not move on injection (read $m, expected 2) — it is not counting emitters"
    fi
done

echo "killed-probe suite: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:credential-channel-survives-a-killed-probe:$pass"
exit 0

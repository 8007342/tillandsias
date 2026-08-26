#!/usr/bin/env bash
# @trace order:899-6pwv
#
# Fixture for scripts/capture.sh.
#
# Arms 1 and 2 REPRODUCE the two incidents this helper exists to prevent, using
# the original idioms, and assert that they still fail. That is deliberate: if
# `| tee X | head -N` ever stops truncating, or `| tail -N` ever stops eating
# the exit status, the helper's justification is gone and someone should know.
# A fixture that only tests the fix cannot tell you the problem was real.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CAP="${TILLANDSIAS_CAPTURE_SH:-$ROOT/scripts/capture.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

[ -x "$CAP" ] || { echo "FAIL: capture.sh not executable at $CAP" >&2; exit 1; }

# A command that prints many lines and then a RESULT line — the shape of every
# e2e step whose last line is the part that matters.
noisy() { bash -c 'for i in $(seq 1 200); do echo "line $i"; done; echo "RESULT: PASS"; exit '"$1"''; }

# The SAME shape, but with the producer forced to OUTLIVE the consumer.
#
# ORDER 899-6pwv, CORRECTED 2026-08-26 after calmecacpilli measured this arm
# racing the scheduler: 0 failures in 12 runs on an idle host, 3 failures in 8
# runs under 4 CPU spinners. It is wired into ./build.sh --check, so it reddened
# the gate at random on any loaded host — and it did so with a verdict that
# named the WRONG LAYER ("needs rechecking on this platform"), sending a reader
# to check coreutils on their distro when the property is timing, not platform.
#
# THE RACE: the arm asserts `tee | head` truncates, which requires `head` to
# exit and SIGPIPE the writer BEFORE the writer finishes. With 200 short lines
# the whole pipeline can complete inside one buffer flush, so under load the
# producer wins, nothing truncates, and the arm concludes the premise is broken.
# The premise was never broken.
#
# THE FIX: emit the head window, then SLEEP, then emit the rest. `head -30` has
# its 30 lines and exits during the sleep, so the writer is guaranteed to still
# be alive with writes remaining. A one-second gap against microsecond
# scheduling is a different regime from a coin flip — not "retry until lucky",
# which calmecacpilli explicitly and rightly ruled out, because a retry would
# make this arm stop noticing the very thing it exists to notice.
noisy_slow() {
    bash -c 'for i in $(seq 1 40); do echo "line $i"; done
             sleep 1
             for i in $(seq 41 200); do echo "line $i"; done
             echo "RESULT: PASS"'
}

# ── arm 1: reproduce the SIGPIPE truncation (yolanda, 2026-08-26) ───────────
noisy_slow 2>&1 | tee "$WORK/piped.log" 2>/dev/null | head -30 > /dev/null
if grep -q 'RESULT: PASS' "$WORK/piped.log"; then
    # Name the layer correctly. This is NOT evidence about the platform's
    # coreutils; the construction above removed the timing variable, so if it
    # still did not truncate, SIGPIPE handling or pipe buffering is what moved.
    bad "tee|head did NOT truncate even with the producer forced to outlive the consumer by 1s — this is a SIGPIPE/buffering property, NOT a platform-coreutils one; do not go audit head(1). capture.sh's premise needs rechecking (899-6pwv)"
else
    ok "REPRODUCED: tee|head truncates the evidence file; RESULT line absent from $(wc -l < "$WORK/piped.log" | tr -d ' ') captured lines"
fi

# ── arm 2: the swallowed exit status, and its ACTUAL precondition ──────────
#
# CORRECTED AFTER THIS ARM FAILED. The first draft asserted flatly that
# `cmd | tail` returns 0 for a failing command. It does not — under `pipefail`,
# which THIS fixture sets, the pipeline propagates 7 and the arm failed. The
# real rule is narrower and worth stating exactly, because the imprecise version
# is the kind of claim that gets quoted later as a fleet rule:
#
#   the status is lost ONLY when pipefail is unset — which is the DEFAULT for
#   an interactive shell, for `bash -c`, and for every ad-hoc command an agent
#   types at a prompt. It is set in most of this repo's scripts.
#
# So the hazard is real precisely where it is least visible: outside the scripts
# that were written carefully.
( set +o pipefail; noisy 7 2>&1 | tail -40 > /dev/null; exit $? )
nopipefail_rc=$?
( set -o pipefail; noisy 7 2>&1 | tail -40 > /dev/null; exit $? )
pipefail_rc=$?
if [ "$nopipefail_rc" -eq 0 ] && [ "$pipefail_rc" -eq 7 ]; then
    ok "REPRODUCED with its precondition named: cmd|tail returns 0 without pipefail (status lost) and 7 with it"
else
    bad "pipe status behaviour differs from the documented rule: without pipefail=$nopipefail_rc (want 0), with pipefail=$pipefail_rc (want 7)"
fi

# ── arm 3: THE FIX — the artifact is complete ──────────────────────────────
"$CAP" --quiet "$WORK/ok.log" -- bash -c 'for i in $(seq 1 200); do echo "line $i"; done; echo "RESULT: PASS"'
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'RESULT: PASS' "$WORK/ok.log"; then
    ok "capture.sh stores the whole output including the RESULT line"
else
    bad "capture.sh lost output or status (rc=$rc)"
fi

# ── arm 4: THE FIX — the command's status survives an excerpt ───────────────
# --tail 5 is exactly the display that destroyed the status in arm 2.
"$CAP" --tail 5 "$WORK/rc.log" -- bash -c 'echo hi; exit 7' > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 7 ]; then
    ok "capture.sh exits 7 while still showing an excerpt — display and status are decoupled"
else
    bad "capture.sh returned $rc for a command that exited 7; the excerpt is still eating the status"
fi
if [ "$(cat "$WORK/rc.log.exit" 2>/dev/null)" = "7" ]; then
    ok "the exit code is recorded beside the log, readable after the fact"
else
    bad "no usable .exit sidecar: '$(cat "$WORK/rc.log.exit" 2>/dev/null)'"
fi

# ── arm 5: truncation is DETECTABLE, which is the whole contract ────────────
head -c 40 "$WORK/ok.log" > "$WORK/cut.log"
if "$CAP" --verify "$WORK/cut.log" >/dev/null 2>&1; then
    bad "--verify accepted a truncated file; the terminator is not load-bearing"
else
    ok "--verify rejects a truncated file"
fi
if "$CAP" --verify "$WORK/ok.log" >/dev/null 2>&1; then
    ok "--verify accepts a complete file"
else
    bad "--verify rejected a file capture.sh itself wrote to completion"
fi

# ── arm 6: NEGATIVE CONTROL — content loss WITH a terminator is caught ──────
# The cheap implementation of this idea checks only for a trailing marker, which
# a file can keep while losing everything above it. That is the same
# artifact-stands-in-for-a-measurement shape the packet catalogues, so the line
# count is verified too.
{ head -n 3 "$WORK/ok.log"; tail -n 1 "$WORK/ok.log"; } > "$WORK/hollow.log"
if "$CAP" --verify "$WORK/hollow.log" >/dev/null 2>&1; then
    bad "--verify accepted a file that kept its terminator but lost its body"
else
    ok "NEGATIVE CONTROL: a file with a valid terminator but a missing body is still rejected"
fi

# ── arm 7: NEGATIVE CONTROL — a genuinely failing command is not masked ─────
# capture.sh must not turn a failure into a pass just because the log is intact.
"$CAP" --quiet "$WORK/failing.log" -- bash -c 'echo nope >&2; exit 3'
rc=$?
if [ "$rc" -eq 3 ] && "$CAP" --verify "$WORK/failing.log" >/dev/null 2>&1; then
    ok "NEGATIVE CONTROL: a failing command still exits 3, and its complete log verifies — completeness is not success"
else
    bad "failing command: rc=$rc, or its complete log failed to verify"
fi
if grep -q 'nope' "$WORK/failing.log"; then
    ok "stderr is captured into the log, not dropped"
else
    bad "stderr did not reach the log"
fi

printf 'capture-helper: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:capture-helper:%d\n' "$pass"

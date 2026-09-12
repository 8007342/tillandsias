#!/usr/bin/env bash
# ORDER 1087-h2z9 follow-up. A gate step that COULD NOT RUN must not report
# what the check would have FOUND.
#
# Measured on esmeraldinha (Windows 11 + WSL2 `tillandsias-build`, Fedora 44):
# `rg` was absent from the distro, scripts/check-cheatsheet-refs.sh exited 2
# ("available neither on this host nor in the tillandsias-builder toolbox"), and
# build.sh's gate-step loop printed its single STEP_ERROR string —
# "a cheatsheet reference does not resolve (1087-h2z9)" — then refused the land
# with LAND_EXIT=3. Zero cheatsheet references had been examined. The verdict was
# not a wrong answer about the cheatsheets; it was an answer about nothing.
#
# Gate steps are DATA (1072-b7eq) and carried exactly one error string, so every
# non-zero exit collapsed to it. STEP_SKIP_EXIT lets a step nominate one code
# meaning could-not-run, which is the vocabulary the sibling tier check already
# had in its own script (`skip:cheatsheet-tiers:cargo-absent`).
#
# REGIME. Arms 1 and 2 EXECUTE the real checker against a reproduced condition
# and pin the two exit codes the whole design rests on being distinct. Arm 3
# pins the wiring that binds them. Arm 4 is a STRUCTURAL assertion on build.sh's
# loop, not an execution of it: the loop is inline in build.sh's gate function
# and cannot be invoked without running a gate. That is a real limit of this
# fixture and is recorded as such rather than dressed up — extracting the loop
# body into a callable function is the follow-up that would let arm 4 execute.
#
# No arm encodes an absolute moment: the conditions are reproduced from the
# host's own state at run time, never from a recorded date or a pinned version.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

STEP="scripts/gate-steps.d/165-1087-h2z9.step"
CHECKER="scripts/check-cheatsheet-refs.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/gate-step-skip-exit.XXXXXX")"
probe=""
cleanup() { rm -rf "$work"; [ -n "$probe" ] && rm -f "$ROOT/$probe"; }
trap cleanup EXIT INT TERM

# ── ARM 1 — THE TOOLING GAP, REPRODUCED RATHER THAN DESCRIBED.
#
# Genuine ABSENCE, not a shadow that fails when run. A stub `rg` on PATH does
# NOT reproduce this: `command -v rg` still finds it, resolve_tool returns it,
# and the checker runs a broken rg, matches nothing, and exits 0 — a vacuous
# pass, which is a different defect from the one measured here. So PATH is
# narrowed to the system directories instead, and `toolbox` is stubbed to fail
# its `--version` probe so the fallback arm cannot resolve either. On a host
# with no toolbox the stub changes nothing.
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/toolbox"
chmod +x "$work/bin/toolbox"

if command -v rg >/dev/null 2>&1 && [ -x /usr/bin/rg ]; then
    ok "SKIPPED arm 1: this host has rg in /usr/bin, which the narrowed PATH cannot exclude"
else
    PATH="$work/bin:/usr/bin:/bin" bash "$CHECKER" >/dev/null 2>"$work/err"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "no rg on host and none in the toolbox -> checker exits 2 (could-not-run)"
    else
        bad "no rg anywhere -> checker exits $rc, expected 2 — STEP_SKIP_EXIT=2 would then nominate the wrong code"
    fi
    if grep -q 'available neither on this host nor in the' "$work/err"; then
        ok "the exit-2 path names the TOOLING gap on stderr, not a cheatsheet verdict"
    else
        bad "the exit-2 path did not explain itself: $(head -1 "$work/err")"
    fi
fi

# ── ARM 2 — THE NEGATIVE CONTROL, AND THE REASON THE FIX CANNOT BE
#           "drop the step". A genuine unresolvable reference must still exit 1
#           and must still refuse. If this ever came back 2, the skip path would
#           swallow a real content failure — the exact downgrade the packet
#           named as its negative control.
if ! bash "$CHECKER" >/dev/null 2>&1; then
    ok "SKIPPED arm 2: the checker is not green on this host as-is, so an injected break proves nothing"
else
    probe="cheatsheets/zzz-skip-exit-probe-$$.md"
    printf '# probe (1087-h2z9 fixture)\n\n@cheatsheet runtime/no-such-cheatsheet-%s.md\n' "$$" \
        > "$ROOT/$probe"
    bash "$CHECKER" >/dev/null 2>&1
    rc=$?
    rm -f "$ROOT/$probe"; probe=""
    if [ "$rc" -eq 1 ]; then
        ok "a genuinely unresolvable reference -> checker exits 1, distinct from the could-not-run 2"
    else
        bad "an unresolvable reference -> checker exits $rc, expected 1 — a content failure sharing the skip code would be silently downgraded"
    fi
fi

# ── ARM 3 — THE WIRING. The step must nominate the code arm 1 observed, and
#           must never nominate the code arm 2 observed.
skip_exit="$(sed -n 's/^STEP_SKIP_EXIT=["]\{0,1\}\([^"]*\)["]\{0,1\}$/\1/p' "$STEP")"
if [ "$skip_exit" = "2" ]; then
    ok "the step nominates exit 2 as could-not-run, matching what the checker actually returns"
else
    bad "the step nominates STEP_SKIP_EXIT='$skip_exit'; the checker's could-not-run code is 2"
fi
if [ "$skip_exit" = "1" ] || [ "$skip_exit" = "0" ]; then
    bad "the step nominates $skip_exit, which is success or the content-failure code — every real refusal in this step would read as a skip"
else
    ok "the nominated code is neither 0 nor 1, so success and content failure keep their meanings"
fi
if grep -q '^STEP_ERROR="..*"$' "$STEP"; then
    ok "the step still carries STEP_ERROR — the exit-1 refusal keeps its sentence"
else
    bad "the step lost STEP_ERROR; a genuine unresolved reference would refuse with no explanation"
fi

# ── ARM 4 — THE RUNNER'S DECISION (structural; see REGIME above).
#           The skip branch must require an EXACT match against the nominated
#           code and a non-empty nomination, and the refusal branch must remain
#           reachable for every other non-zero exit.
loop="$(sed -n '/for _step_file in .*gate-steps\.d/,/^    done$/p' build.sh)"
if [ -z "$loop" ]; then
    bad "could not locate the gate-step loop in build.sh — this fixture has drifted from the code it pins"
else
    if printf '%s' "$loop" | grep -q '\[ "\$_step_rc" -eq "\$STEP_SKIP_EXIT" \]'; then
        ok "the skip branch tests an EXACT equality against the nominated code"
    else
        bad "the skip branch does not test exact equality against STEP_SKIP_EXIT"
    fi
    if printf '%s' "$loop" | grep -q '\[ -n "\$STEP_SKIP_EXIT" \]'; then
        ok "the skip branch requires a non-empty nomination, so an unset field cannot open it"
    else
        bad "the skip branch does not require STEP_SKIP_EXIT to be non-empty — an unset field could open it"
    fi
    if printf '%s' "$loop" | grep -q 'STEP_SKIP_EXIT=""; STEP_SKIP_DESC=""'; then
        ok "both skip fields are reset per step, so one step's nomination cannot leak into the next"
    else
        bad "STEP_SKIP_EXIT is not reset between steps — a nomination would leak to every later step"
    fi
    if printf '%s' "$loop" | grep -q 'STEP_ERROR:-\$STEP_SCRIPT failed'; then
        ok "the refusal branch survives and still prints STEP_ERROR for every non-nominated non-zero exit"
    else
        bad "the refusal branch is gone or no longer prints STEP_ERROR"
    fi
fi

echo "gate-step-skip-exit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

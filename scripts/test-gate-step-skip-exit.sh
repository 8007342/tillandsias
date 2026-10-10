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
# REGIME. Arms 1 and 2 EXECUTE a stub subject (since 1570-k4fx; see below)
# against a reproduced condition and pin the two exit codes the whole design
# rests on being distinct. Arm 3
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

# ORDER 1570-k4fx: RE-SUBJECTED ONTO A STUB. Arms 1-3 used to drive
# scripts/check-cheatsheet-refs.sh and step 165, whose exit 2 meant "no rg".
# That checker is now Lua with no tool, so it has no could-not-run condition
# and step 165 nominates none. The STEP_SKIP_EXIT contract this fixture pins is
# unchanged and still used by ~30 steps, so it is exercised against a STUB
# subject kept in this fixture's own data: a checker that needs a tool no host
# carries, and a step file that nominates its could-not-run code. A stub, not
# another real tool-dependent checker, so the next port cannot strand it again.
work="$(mktemp -d "${TMPDIR:-/tmp}/gate-step-skip-exit.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

TOOL="tillandsias-skip-exit-probe-tool"   # a name no real host carries
CHECKER="$work/stub-checker.sh"
STEP="$work/999-stub.step"
cat > "$CHECKER" <<'STUB'
#!/bin/sh
# Stub subject: COULD NOT RUN (exit 2) without its tool; a content failure
# (exit 1) when the reference it is given does not resolve; ok (0) otherwise.
if ! command -v tillandsias-skip-exit-probe-tool >/dev/null 2>&1; then
    echo "error: tillandsias-skip-exit-probe-tool is available neither on this host nor in the toolbox" >&2
    exit 2
fi
[ -f "$1" ] || { echo "unresolved reference: $1" >&2; exit 1; }
exit 0
STUB
cat > "$STEP" <<'STEPDATA'
STEP_DESC="Stub: checking a reference resolves"
STEP_SCRIPT="stub-checker.sh"
STEP_ERROR="a reference does not resolve (stub)"
STEP_OK="Stub passed"
STEP_SKIP_EXIT=2
STEP_SKIP_DESC="the stub's tool is absent"
STEPDATA
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/$TOOL"
chmod +x "$work/bin/$TOOL"
: > "$work/present-ref"

# ── ARM 1 — THE TOOLING GAP: genuine ABSENCE gives the could-not-run code,
#           and says so on stderr, never as a content verdict.
PATH="/usr/bin:/bin" sh "$CHECKER" "$work/present-ref" >/dev/null 2>"$work/err"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "tool absent -> the subject exits 2 (could-not-run)"
else
    bad "tool absent -> the subject exits $rc, expected 2 — STEP_SKIP_EXIT=2 would then nominate the wrong code"
fi
if grep -q 'available neither on this host nor in the' "$work/err"; then
    ok "the exit-2 path names the TOOLING gap on stderr, not a content verdict"
else
    bad "the exit-2 path did not explain itself: $(head -1 "$work/err")"
fi

# ── ARM 2 — THE NEGATIVE CONTROL: with the tool present, an unresolvable
#           reference exits 1 (a content failure must never share the skip
#           code), and a resolvable one exits 0.
PATH="$work/bin:/usr/bin:/bin" sh "$CHECKER" "$work/no-such-ref" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
    ok "a genuinely unresolvable reference -> exit 1, distinct from the could-not-run 2"
else
    bad "an unresolvable reference -> exit $rc, expected 1 — a content failure sharing the skip code would be silently downgraded"
fi
PATH="$work/bin:/usr/bin:/bin" sh "$CHECKER" "$work/present-ref" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "POSITIVE CONTROL: tool present and reference resolves -> exit 0" \
                || bad "tool present and reference resolves -> exit $rc, expected 0"

# ── ARM 3 — THE WIRING. The step must nominate the code arm 1 observed, and
#           must never nominate the code arm 2 observed.
skip_exit="$(sed -n 's/^STEP_SKIP_EXIT=["]\{0,1\}\([^"]*\)["]\{0,1\}$/\1/p' "$STEP")"
if [ "$skip_exit" = "2" ]; then
    ok "the step nominates exit 2 as could-not-run, matching what the subject actually returns"
else
    bad "the step nominates STEP_SKIP_EXIT='$skip_exit'; the subject's could-not-run code is 2"
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
# And step 165 itself, whose subject now has no could-not-run condition, must
# nominate NOTHING: its only exit 2 is a missing cheatsheets/ dir, which must
# refuse rather than skip (1570-k4fx).
if grep -q '^STEP_SKIP_EXIT=' scripts/gate-steps.d/165-1087-h2z9.step; then
    bad "step 165 still nominates a skip code, though check-cheatsheet-refs.lua needs no tool — a broken checkout would read as a skip"
else
    ok "step 165 nominates no skip: its tool-free subject has no could-not-run condition"
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
    if grep -q 'STEP_ERROR:-\$_step_path failed' <<<"$loop"; then
        ok "the refusal branch survives and still prints STEP_ERROR for every non-nominated non-zero exit"
    else
        bad "the refusal branch is gone or no longer prints STEP_ERROR"
    fi
fi

echo "gate-step-skip-exit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

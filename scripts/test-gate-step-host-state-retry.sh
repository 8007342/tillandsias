#!/usr/bin/env bash
# @trace order:1765-q7rg, spec:ci-release
#
# A GATE STEP THAT DECLARES STEP_HOST_STATE GETS ONE RETRY, AND ONLY ONE.
#
# credential-cold-state-probe (900-z3kv, keyring) and door-index-lock-sweep
# (1650-fb7z, load) can disagree with themselves on a healthy tree, and each
# such red evicted a good PR from the land queue as violation:. build.sh's
# step runner now re-runs a declared host-state step once after a settle: a
# pass then is a pass, and a second red stays red but prints
# flaky:<step>:<first>,<second> for the queue to re-queue once.
#
# Every arm EXECUTES the real loop through `./build.sh --gate-steps <root>`
# (1384-bqhy) over a scratch root whose stub steps count their own runs, so
# "retried once" is a count, not a grep of build.sh:
#   1 FLAKE-ONCE  a host-state step red then green: the gate passes, the step
#                 ran exactly twice, and no flaky: line is printed
#   2 RED-TWICE   a host-state step red twice: the gate stays red, the step ran
#                 exactly twice, and flaky:<step>:<v1>,<v2> names both verdicts
#   3 NO-FIELD    the same red-then-green step WITHOUT the field: the gate is
#                 red after ONE run (NEGATIVE CONTROL — no field, no retry)
#   4 GREEN       a host-state step that passes runs once (no retry on green)
#
# Prints one summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1
# On MSYS build.sh re-execs into the tillandsias-build distro, which cannot see
# this shell's mktemp root; the gate runs this step inside that distro.
case "$(uname -s)" in
    Linux|Darwin) ;;
    *) echo "skip:gate-step-host-state-retry:$(uname -s)-re-execs-build-sh-into-wsl — runs inside the builder distro's gate"; exit 0 ;;
esac

pass=0; fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/gate-step-host-state.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

# root <name> <reds-before-green> <host-state value or empty>
# A scratch root with ONE step whose stub fails its first <reds> runs with a
# violation: line and passes after; each run appends a line to runs.log.
root() {
    local r="$work/$1" reds="$2" hs="$3"
    mkdir -p "$r/scripts/gate-steps.d"
    : > "$r/runs.log"
    sed -e "s|@RUNS@|$r/runs.log|" -e "s|@REDS@|$reds|" > "$r/scripts/stub-hs.sh" <<'STUB'
#!/usr/bin/env bash
echo run >> "@RUNS@"
n="$(wc -l < "@RUNS@" | tr -d ' ')"  # BSD wc pads the count
if [ "$n" -le @REDS@ ]; then echo "violation:stub-hs:run-$n"; exit 1; fi
echo "ok:stub-hs:run-$n"
STUB
    {
        echo 'STEP_DESC="Stub host-state step (1765-q7rg fixture)"'
        echo 'STEP_SCRIPT="scripts/stub-hs.sh"'
        echo 'STEP_ERROR="stub host-state step failed"'
        echo 'STEP_OK="Stub host-state step passed"'
        [ -z "$hs" ] || echo "STEP_HOST_STATE=\"$hs\""
    } > "$r/scripts/gate-steps.d/500-stub.step"
    R="$r"
}
gate() {
    O="$(TILLANDSIAS_GATE_HOST_STATE_SETTLE_S=0 ./build.sh --gate-steps "$R" 2>&1)"; RC=$?
    RUNS="$(wc -l < "$R/runs.log" | tr -d ' ')"
}

root flake-once 1 keyring; gate
if [ "$RC" -eq 0 ] && [ "$RUNS" = 2 ] && ! grep -q '^flaky:' <<<"$O"; then
    ok "1 FLAKE-ONCE a host-state step red then green passes after exactly one retry"
else
    bad "1 FLAKE-ONCE wanted rc=0 runs=2 and no flaky:; got rc=$RC runs=$RUNS
$O"
fi

root red-twice 9 load; gate
if [ "$RC" -ne 0 ] && [ "$RUNS" = 2 ] \
   && grep -qx 'flaky:stub-hs.sh:violation:stub-hs:run-1,violation:stub-hs:run-2' <<<"$O" \
   && grep -q 'stub host-state step failed' <<<"$O"; then
    ok "2 RED-TWICE a host-state step red twice stays red and reads flaky:<step>:<v1>,<v2>"
else
    bad "2 RED-TWICE wanted rc!=0 runs=2 flaky:stub-hs.sh:violation:stub-hs:run-1,violation:stub-hs:run-2; got rc=$RC runs=$RUNS
$O"
fi

root no-field 1 ""; gate
if [ "$RC" -ne 0 ] && [ "$RUNS" = 1 ] && ! grep -qE 'retry:stub-hs|^flaky:' <<<"$O"; then
    ok "3 NO-FIELD a step that declares no host state is red after one run, never retried"
else
    bad "3 NO-FIELD wanted rc!=0 runs=1 and no retry/flaky line; got rc=$RC runs=$RUNS
$O"
fi

root green 0 keyring; gate
if [ "$RC" -eq 0 ] && [ "$RUNS" = 1 ]; then
    ok "4 GREEN a host-state step that passes runs once"
else
    bad "4 GREEN wanted rc=0 runs=1; got rc=$RC runs=$RUNS
$O"
fi

echo "gate-step-host-state-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

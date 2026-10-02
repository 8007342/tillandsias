#!/usr/bin/env bash
# @trace order:1384-bqhy
#
# test-script-run-verb.sh — `tillandsias-plan script run` is the ONE runner for a
# Lua decider, and `script classify` the ONE classifier the gate loop and the
# preflight door both read (1384-bqhy verifiable_closure, arms in its order):
#
#   1 OK           verdict.ok("x", 3) prints exactly `ok:x:3`, exit 0
#   2 REFUSED      verdict.refused("x", detail): exit 1, `refused:x` on stdout,
#                  the detail on stderr
#   3 NO VERDICT   a script that returns without one: exit 1,
#                  `refused:no-verdict:<name>` — silent green is unconstructible
#   4 TIMEOUT      a script that outlives --timeout: exit 124, `status=timed_out`
#   5 STEP_LUA     build.sh's own gate-steps loop, over a SCRATCH root, runs a
#                  .step with STEP_LUA and no STEP_SCRIPT and shows its verdict;
#                  a .step naming a missing .lua is refused, not skipped; a
#                  .step naming both is refused
#   6 TIMING       the timing record lands in TILLANDSIAS_TIMING_LOG and
#                  /tmp/tillandsias-timing.jsonl does not grow (1204-3s2s)
#   7 CLASSIFY     advisory / skip / could-not-run / timed_out / plain refusal classify to
#                  the four kinds the door prints; ONE `fn classify` in the
#                  tree, and both build.sh call sites reach it through the binary
#
# Hermetic: every tree it writes is under target/plan-scratch; the live
# checkout is never planted in (1516-wru4).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ]; then
    echo "skip:script-run-verb:no-validator — no runnable tillandsias-plan; build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
mkdir -p "$ROOT/target/plan-scratch"
W="$(mktemp -d "$ROOT/target/plan-scratch/script-run.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM
export TILLANDSIAS_TIMING_LOG="$W/timing.jsonl"

lua() { printf '%s\n' "$2" > "$W/$1.lua"; }
run() { # run <name> [runner args...] -> OUT ERR RC
    local n="$1"; shift
    OUT="$("$PLAN" script run "$W/$n.lua" "$@" 2>"$W/$n.err")"; RC=$?; ERR="$(cat "$W/$n.err")"
}

# ── ARM 1 ──────────────────────────────────────────────────────────────────
lua okv 'verdict.ok("x", 3)'
run okv
[ "$RC" -eq 0 ] && [ "$OUT" = "ok:x:3" ] && ok "ARM 1: verdict.ok(\"x\", 3) prints exactly ok:x:3 and exits 0" \
    || bad "ARM 1: rc=$RC out='$OUT'"

# ── ARM 2 ──────────────────────────────────────────────────────────────────
lua refv 'verdict.refused("x", "the detail goes to stderr")'
run refv
[ "$RC" -eq 1 ] && [ "$OUT" = "refused:x" ] && grep -q 'the detail goes to stderr' <<<"$ERR" \
    && ! grep -q 'detail' <<<"$OUT" \
    && ok "ARM 2: verdict.refused exits 1 with refused:x on stdout and the detail on stderr only" \
    || bad "ARM 2: rc=$RC out='$OUT' err='$ERR'"

# ── ARM 3 ──────────────────────────────────────────────────────────────────
lua silent 'local x = 1 + 1'
run silent
[ "$RC" -eq 1 ] && [ "$OUT" = "refused:no-verdict:silent" ] \
    && ok "ARM 3: a script ending without a verdict exits 1 with refused:no-verdict:silent" \
    || bad "ARM 3: rc=$RC out='$OUT'"

# ── ARM 4 ──────────────────────────────────────────────────────────────────
lua sleeper 'local t = time.now_ms(); while time.now_ms() - t < 5000 do end; verdict.ok("late")'
run sleeper --timeout 300ms
[ "$RC" -eq 124 ] && grep -qx 'status=timed_out' <<<"$OUT" && ! grep -q '^ok:' <<<"$OUT" \
    && ok "ARM 4: a script outliving --timeout 300ms exits 124 printing status=timed_out, and never ok" \
    || bad "ARM 4: rc=$RC out='$OUT'"

# ── ARM 5: build.sh's own loop over scratch roots ──────────────────────────
mkroot() { mkdir -p "$1/scripts/gate-steps.d" "$1/scripts/lua"; }
R="$W/root-ok"; mkroot "$R"
printf '%s\n' 'verdict.ok("fixture-lua-step", 7)' > "$R/scripts/lua/fixture-step.lua"
printf 'STEP_DESC="a Lua step"\nSTEP_LUA="scripts/lua/fixture-step.lua"\nSTEP_ERROR="lua step failed"\nSTEP_OK="lua step passed"\n' > "$R/scripts/gate-steps.d/100-lua.step"
o5="$(cd "$ROOT" && ./build.sh --gate-steps "$R" 2>&1)"; r5=$?
R2="$W/root-missing"; mkroot "$R2"
printf 'STEP_DESC="a missing Lua step"\nSTEP_LUA="scripts/lua/absent.lua"\n' > "$R2/scripts/gate-steps.d/100-lua.step"
o5m="$(cd "$ROOT" && ./build.sh --gate-steps "$R2" 2>&1)"; r5m=$?
R3="$W/root-both"; mkroot "$R3"
printf '%s\n' 'verdict.ok("both")' > "$R3/scripts/lua/both.lua"; printf 'echo ok:both\n' > "$R3/scripts/both.sh"
printf 'STEP_DESC="both"\nSTEP_LUA="scripts/lua/both.lua"\nSTEP_SCRIPT="scripts/both.sh"\n' > "$R3/scripts/gate-steps.d/100-both.step"
o5b="$(cd "$ROOT" && ./build.sh --gate-steps "$R3" 2>&1)"; r5b=$?
if [ "$r5" -eq 0 ] && grep -q 'ok:fixture-lua-step:7' <<<"$o5" \
   && [ "$r5m" -ne 0 ] && grep -q 'absent.lua, which does not exist' <<<"$o5m" \
   && [ "$r5b" -ne 0 ] && grep -q 'names both STEP_SCRIPT and STEP_LUA' <<<"$o5b"; then
    ok "ARM 5: build.sh's loop runs a STEP_LUA-only step and shows its verdict; a missing .lua and a step naming both are refused"
else
    bad "ARM 5: ok-root rc=$r5 missing rc=$r5m both rc=$r5b; ok-root tail: $(tail -3 <<<"$o5" | tr '\n' '|')"
fi

# ── ARM 6: timing goes where it is told, and never to /tmp ─────────────────
shared_before=0; [ -f /tmp/tillandsias-timing.jsonl ] && shared_before="$(wc -l < /tmp/tillandsias-timing.jsonl)"
: > "$TILLANDSIAS_TIMING_LOG"
run okv
shared_after=0; [ -f /tmp/tillandsias-timing.jsonl ] && shared_after="$(wc -l < /tmp/tillandsias-timing.jsonl)"
if grep -q '"kind":"script-run"' "$TILLANDSIAS_TIMING_LOG" && grep -q '"verdict":"ok:x:3"' "$TILLANDSIAS_TIMING_LOG" \
   && [ "$shared_after" -eq "$shared_before" ]; then
    ok "ARM 6: the timing record lands in TILLANDSIAS_TIMING_LOG and /tmp/tillandsias-timing.jsonl did not grow"
else
    bad "ARM 6: log='$(cat "$TILLANDSIAS_TIMING_LOG")' shared $shared_before->$shared_after"
fi

# ── ARM 7: advisory and one classifier, reached by both call sites ─────────
printf 'skip:x:not-here\n' > "$W/c-skip"; printf 'could-not-run:x:no-meminfo\n' > "$W/c-cnr"
printf 'partial\n' > "$W/c-to"; printf 'violation: the tree is wrong\n' > "$W/c-ref"
printf 'centicolon: R=1 regime=baseline (advisory)\n' > "$W/c-adv"
k1="$("$PLAN" script classify --rc 1 --file "$W/c-skip")"
k2="$("$PLAN" script classify --rc 3 --file "$W/c-cnr")"
k3="$("$PLAN" script classify --rc 0 --status timed_out --file "$W/c-to")"
k4="$("$PLAN" script classify --rc 1 --file "$W/c-ref")"
k5="$("$PLAN" script classify --rc 0 --file "$W/c-adv")"
# ONE OUTCOME classifier: every Rust fn classifying from an exit code. (Other
# `fn classify` in the tree classify questions, commands and refs, not outcomes.)
defs="$(cd "$ROOT" && git grep -n --untracked -E 'fn classify[a-z_]*\(rc: i32' -- crates | wc -l | tr -d ' ')"
sites="$(grep -c 'script classify --rc' "$ROOT/build.sh")"
oldgrep="$(grep -c "grep -qE '^skip:' \"\$_pf_tmp\"" "$ROOT/build.sh")"
lua lclass 'verdict.ok("k", verdict.classify{rc=1, text="skip:x"})'
run lclass
lua advisory 'verdict.advisory("centicolon: R=1 regime=baseline (advisory)")'
run advisory
if [ "$k1 $k2 $k3 $k4 $k5" = "skip could-not-run timed-out refused advisory" ] && [ "$defs" = 1 ] \
   && [ "$sites" = 2 ] && [ "$oldgrep" = 0 ] && [ "$OUT" = "centicolon: R=1 regime=baseline (advisory)" ] && [ "$RC" -eq 0 ]; then
    ok "ARM 7: advisory is verbatim and classifies advisory; skip/could-not-run/timed_out/refusal retain their kinds through ONE classifier"
else
    bad "ARM 7: kinds='$k1 $k2 $k3 $k4 $k5' defs=$defs build.sh-sites=$sites old-door-grep=$oldgrep lua='$OUT' rc=$RC"
fi

echo "script-run-verb: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

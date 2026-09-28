#!/usr/bin/env bash
# @trace order:1443-8pur, spec:command-runtime
#
# test-run-verb-agent-door.sh — `tillandsias-plan run … -- <argv…>`, the agent
# door: argv through the policy engine, then tillandsias-exec.
#
#   2  an argument with a space, a double quote and `*` reaches the child as
#      ONE argv entry (a child prints argc and argv[1])
#   4  a request the policy refuses spawns nothing, prints the refusal and exits
#      1; the refusal is audited with no run_id, a run with one
#   5  the child sees only the proc.run base environment, TILLANDSIAS_* and the
#      --env additions: an exported GH_TOKEN does not reach it
#   7  the plain form mirrors the child: its bytes pass through, its exit code
#      is the verb's, a deadline is 124, an unknown program is 127
#   1  --json: exactly one object with the ten keys; a child's non-zero exit,
#      a deadline and a spawn failure are reported with the verb exiting 0
#   6  a capture past --capture-bytes is truncated:true and ok:false
#   8  the plain form's limitation, pinned: a refusal and a child's exit 1 share
#      rc 1 there; --json tells them apart; a usage error is 2
#   3  --argv-json -: argv as a JSON array on stdin, delivered byte for byte
#      (C:\x\. unconverted), through the same policy; malformed input is 2
#
# Pre-fix: FAILS at arm 2 (`run` is an unknown subcommand).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/run-verb-agent-door.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/audit.jsonl"
jget() { "$PLAN" json get "$@"; }

printf '#!/bin/sh\nprintf "argc=%%s\\n" "$#"\nprintf "argv1=[%%s]\\n" "$1"\n' >"$W/argc.sh"

# ── 2 ───────────────────────────────────────────────────────────────────────
out="$("$PLAN" run -- sh "$W/argc.sh" 'a "b" *' second 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'argc=2' <<<"$out" && grep -qxF 'argv1=[a "b" *]' <<<"$out"; then
    ok "arm 2: an argument with a space, a double quote and * reaches the child as ONE entry"
else
    bad "arm 2: rc=$rc [$out]"
fi

# ── 4 ───────────────────────────────────────────────────────────────────────
out="$("$PLAN" run -- bash -c "touch $W/marker" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$W/marker" ] && grep -qx 'refused:policy:no-shell-strings' <<<"$out" &&
    grep -q '^why: ' <<<"$out" && grep -q '^remedy: ' <<<"$out"; then
    ok "arm 4: a refused request prints the refusal, exits 1, and spawns nothing"
else
    bad "arm 4: rc=$rc marker=$([ -e "$W/marker" ] && echo PRESENT || echo absent) [$out]"
fi
refused="$(grep '"rule_id":"no-shell-strings"' "$W/audit.jsonl" | tail -n 1)"
ran="$(grep '"caller":"run"' "$W/audit.jsonl" | grep '"decision":"allow"' | head -n 1)"
if [ "$(jget -r '.run_id' <<<"$refused" 2>/dev/null)" = null ] &&
    [ "$(jget -r '.caller' <<<"$refused" 2>/dev/null)" = run ] &&
    [ "$(jget -r '.run_id' <<<"$ran" 2>/dev/null)" != null ] && [ -n "$ran" ]; then
    ok "arm 4: the audit records the refusal with no run_id and the run with its run_id"
else
    bad "arm 4 audit: refused=[$refused] ran=[$ran]"
fi

# ── 5 ───────────────────────────────────────────────────────────────────────
out="$(GH_TOKEN=leak-me TILLANDSIAS_RUN_FIXTURE=1 "$PLAN" run --env ADDED=yes -- env 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^GH_TOKEN=' <<<"$out" && grep -qx 'ADDED=yes' <<<"$out" &&
    grep -qx 'TILLANDSIAS_RUN_FIXTURE=1' <<<"$out" && grep -qx 'LC_ALL=C' <<<"$out"; then
    ok "arm 5: the child gets the base set, TILLANDSIAS_* and --env; an exported GH_TOKEN does not reach it"
else
    bad "arm 5: rc=$rc [$(grep -E '^(GH_TOKEN|ADDED|TILLANDSIAS_RUN_FIXTURE|LC_ALL)=' <<<"$out" | tr '\n' ' ')]"
fi

# ── 7 ───────────────────────────────────────────────────────────────────────
"$PLAN" run -- sh -e "$W/argc.sh" >/dev/null 2>&1
"$PLAN" run -- false >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "arm 7: a child's non-zero exit is the verb's exit" || bad "arm 7 false: rc=$rc"
printf 'hello-from-stdin' >"$W/in.txt"
out="$("$PLAN" run --stdin-file "$W/in.txt" -- cat 2>&1)"
[ "$out" = "hello-from-stdin" ] && ok "arm 7: --stdin-file feeds the child's stdin" || bad "arm 7 stdin: [$out]"
"$PLAN" run --timeout-ms 300 -- sleep 5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 124 ] && ok "arm 7: a deadline is exit 124" || bad "arm 7 timeout: rc=$rc"
"$PLAN" run -- no-such-program-8pur >/dev/null 2>&1; rc=$?
[ "$rc" -eq 127 ] && ok "arm 7: an unknown program is exit 127" || bad "arm 7 missing: rc=$rc"
out="$("$PLAN" run --cwd "$W" -- pwd 2>&1)"
[ "$out" = "$W" ] && ok "arm 7: --cwd sets the child's working directory" || bad "arm 7 cwd: [$out]"
"$PLAN" run 'echo hi' >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "arm 7: there is no command-string form (a positional string is a usage error)" || bad "arm 7 string: rc=$rc"

# ── 1 (slice 2: --json) ──────────────────────────────────────────────────────
out="$("$PLAN" run --json --timeout-ms 5000 -- printf "a b" 2>/dev/null)"; rc=$?
keys="$(jget -c 'keys' <<<"$out" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$(grep -c . <<<"$out")" = 1 ] &&
    [ "$keys" = '["argv","code","ok","policy","run_id","status","stderr","stdout","truncated","wall_ms"]' ] &&
    [ "$(jget -r '.stdout' <<<"$out")" = "a b" ] && [ "$(jget -r '.status' <<<"$out")" = exited ] &&
    [ "$(jget -r '.ok' <<<"$out")" = true ] && [ "$(jget -r '.run_id' <<<"$out")" != null ]; then
    ok "arm 1: --json prints exactly one object with the ten keys, exit 0"
else
    bad "arm 1: rc=$rc keys=[$keys] out=[$out]"
fi

out="$("$PLAN" run --json -- false 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(jget -r '.code' <<<"$out")" = 1 ] && [ "$(jget -r '.ok' <<<"$out")" = false ] &&
    [ "$(jget -r '.status' <<<"$out")" = exited ]; then
    ok "arm 1: a non-zero child exit is reported as code, with the verb exiting 0"
else
    bad "arm 1 nonzero: rc=$rc [$out]"
fi
out="$("$PLAN" run --json --timeout-ms 300 -- sleep 5 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jget -r '.status' <<<"$out")" = timed_out ] && [ "$(jget -r '.code' <<<"$out")" = null ] &&
    ok "arm 1: a deadline is status timed_out with no invented code, exit 0" || bad "arm 1 timeout: rc=$rc [$out]"
out="$("$PLAN" run --json -- no-such-program-8pur 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jget -r '.status' <<<"$out")" = spawn_failed ] &&
    ok "arm 1: an unknown program is status spawn_failed, exit 0" || bad "arm 1 spawn: rc=$rc [$out]"

# ── 4 (JSON half) ────────────────────────────────────────────────────────────
out="$("$PLAN" run --json -- bash -c "touch $W/marker2" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$W/marker2" ] && [ "$(jget -r '.status' <<<"$out")" = policy_denied ] &&
    [ "$(jget -r '.run_id' <<<"$out")" = null ] && [ "$(jget -r '.policy.rule_id' <<<"$out")" = no-shell-strings ] &&
    [ -n "$(jget -r '.policy.why' <<<"$out")" ] && [ -n "$(jget -r '.policy.remedy' <<<"$out")" ]; then
    ok "arm 4: --json refusal is status policy_denied with rule_id/why/remedy and no run_id, exit 1, nothing spawned"
else
    bad "arm 4 json: rc=$rc [$out]"
fi

# ── 6 (slice 2) ─────────────────────────────────────────────────────────────
out="$("$PLAN" run --json --capture-bytes 1024 -- head -c 4096 /dev/zero 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(jget -r '.truncated' <<<"$out")" = true ] && [ "$(jget -r '.ok' <<<"$out")" = false ] &&
    [ "$(jget -r '.code' <<<"$out")" = 0 ]; then
    ok "arm 6: stdout past --capture-bytes is truncated:true and ok:false (code 0)"
else
    bad "arm 6: rc=$rc [$(cut -c1-200 <<<"$out")]"
fi

# ── 8: THE PLAIN FORM'S LIMITATION, PINNED ──────────────────────────────────
# Without --json the verb mirrors the child's exit code, so a refusal and a
# child that exits 1 are the same rc. --json is the interface that tells them
# apart. Both halves are asserted so the limitation is tested, not just stated.
"$PLAN" run -- false >/dev/null 2>&1; rc_child=$?
"$PLAN" run -- bash -c true >/dev/null 2>&1; rc_refused=$?
st_child="$("$PLAN" run --json -- false 2>/dev/null | "$PLAN" json get -r '.status')"
st_refused="$("$PLAN" run --json -- bash -c true 2>/dev/null | "$PLAN" json get -r '.status')"
if [ "$rc_child" -eq 1 ] && [ "$rc_refused" -eq 1 ] && [ "$st_child" = exited ] && [ "$st_refused" = policy_denied ]; then
    ok "arm 8: plain form cannot tell a refusal from a child's exit 1 by rc (both 1); --json can (exited vs policy_denied)"
else
    bad "arm 8: plain rc child=$rc_child refused=$rc_refused; json status child=[$st_child] refused=[$st_refused]"
fi
"$PLAN" run --bogus-flag -- true >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "arm 8: a usage error is 2, never 1 or 4 (so a binary without a flag is not a refusal)" || bad "arm 8 usage: rc=$rc"

# ── 3 (slice 3: --argv-json -) ──────────────────────────────────────────────
# argv arrives as a JSON array on stdin, so no argument is on the command line
# for MSYS or wsl.exe to convert. On Linux the element must arrive byte for
# byte; the Git Bash contrast (the positional form rewritten under MSYS) is a
# filed event from yolanda.
out="$(printf '%s' '["printf","%s","C:\\x\\."]' | "$PLAN" run --json --argv-json - 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(jget -r '.stdout' <<<"$out")" = 'C:\x\.' ] && [ "$(jget -r '.status' <<<"$out")" = exited ]; then
    ok "arm 3: --argv-json - delivers [\"printf\",\"%s\",\"C:\\\\x\\\\.\"] and the child prints C:\\x\\. unconverted"
else
    bad "arm 3: rc=$rc [$out]"
fi
out="$(printf '%s' '["sh","'"$W"'/argc.sh","a \"b\" *"]' | "$PLAN" run --argv-json - 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -qx 'argc=1' <<<"$out" && grep -qxF 'argv1=[a "b" *]' <<<"$out" &&
    ok "arm 3: --argv-json keeps a space, a quote and * inside one entry" || bad "arm 3 argc: rc=$rc [$out]"
printf '%s' '["bash","-c","touch '"$W"'/marker3"]' | "$PLAN" run --argv-json - >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$W/marker3" ] &&
    ok "arm 3: argv from --argv-json goes through the same policy (a shell string is refused, nothing spawned)" ||
    bad "arm 3 policy: rc=$rc marker=$([ -e "$W/marker3" ] && echo PRESENT || echo absent)"
for bad_in in '"git status"' '[]' '["git",1]' 'not json'; do
    printf '%s' "$bad_in" | "$PLAN" run --argv-json - >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] && ok "arm 3: --argv-json rejects $bad_in as a usage error (2)" || bad "arm 3 reject $bad_in: rc=$rc"
done
printf '%s' '["true"]' | "$PLAN" run --argv-json - -- echo also >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "arm 3: argv from both --argv-json and -- is a usage error" || bad "arm 3 both: rc=$rc"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: run-verb-agent-door $pass/$total (1443-8pur)"
    exit 0
fi
echo "FAIL: run-verb-agent-door $pass/$total (1443-8pur)"
exit 1

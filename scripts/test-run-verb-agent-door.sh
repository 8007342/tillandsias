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
#   (arms 1 and 6 arrive with the --json slice, arm 3 with --argv-json)
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

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: run-verb-agent-door $pass/$total (1443-8pur)"
    exit 0
fi
echo "FAIL: run-verb-agent-door $pass/$total (1443-8pur)"
exit 1

#!/usr/bin/env bash
# @trace order:1404-4x3r
#
# test-drain-queue-bare-refuses.sh — 1404-4x3r's verifiable closure.
#
# drain-queue.sh claims a packet and launches a PAID agent session per ready
# row. Run with no arguments it used to drain the whole queue: on yoga,
# 2026-09-26, a bare run claimed packet 278 and ran codex for ~6 minutes.
#
# NEVER run the real script bare to reproduce that. Every arm here runs a COPY
# inside a scratch repo whose ./repeat, scripts/claim-ledger-node.sh and plan
# binary are stubs that only RECORD being called. The script reaches both by
# relative path, so the copy cannot touch the real ones.
#
# ARM 1  a bare invocation is REFUSED, exits non-zero, names --drain, and the
#        record is EMPTY (no claim, no launch).
#        PRE-FIX RESULT: FAILS, the record shows a claim and a repeat launch.
# ARM 2  --dry-run alone still prints the plan and records nothing.
# ARM 3  POSITIVE CONTROL: --drain --limit 1 claims and launches exactly once.
#        Without it, ARM 1 could pass because the stubs were unreachable.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DQ="$ROOT/scripts/drain-queue.sh"
[ -f "$DQ" ] || { echo "skip:drain-queue-bare-fixture:script-absent"; exit 0; }

W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

_sandbox() { # $1 = dir; prints nothing, builds a repo whose spenders only record
    local r="$1" rec="$1.calls"
    mkdir -p "$r/scripts" "$r/plan"
    cp "$DQ" "$r/scripts/drain-queue.sh"
    : > "$rec"
    printf '#!/bin/sh\necho "repeat $*" >> "%s"\nexit 0\n' "$rec" > "$r/repeat"
    printf '#!/bin/sh\necho "claim-ledger-node $*" >> "%s"\necho "ok:$1:$2"\n' "$rec" > "$r/scripts/claim-ledger-node.sh"
    # The plan binary answers the one query the script makes with one ready row.
    printf '#!/bin/sh\nprintf "278\\tfixture-packet\\tv0.5\\tlinux\\n"\n' > "$r/fake-plan"
    chmod +x "$r/repeat" "$r/scripts/claim-ledger-node.sh" "$r/fake-plan"
    git -C "$r" init -q 2>/dev/null
}
_run() { # $1 = dir, rest = args
    local r="$1"; shift
    (cd "$r" && TILLANDSIAS_PLAN_BIN="$r/fake-plan" bash scripts/drain-queue.sh "$@" 2>&1)
}

# --- ARM 1: bare is refused and spends nothing ------------------------------
R1="$W/bare"; _sandbox "$R1"
out1="$(_run "$R1")"; rc1=$?
rec1="$(cat "$R1.calls")"
if [ "$rc1" -ne 0 ] && [ -z "$rec1" ] && [[ "$out1" == *"refused:drain-queue:bare-invocation"* ]] && [[ "$out1" == *"--drain"* ]]; then
    ok "ARM 1 a bare invocation is refused (rc=$rc1), names --drain, and records no claim or launch"
else
    bad "ARM 1 a bare invocation was not refused (rc=$rc1); it would have run: $(printf '%s' "$rec1" | tr '\n' ';')"
fi

# --- ARM 2: --dry-run still prints the plan, spends nothing -----------------
R2="$W/dry"; _sandbox "$R2"
out2="$(_run "$R2" --dry-run)"; rc2=$?
rec2="$(cat "$R2.calls")"
if [ "$rc2" -eq 0 ] && [ -z "$rec2" ] && [[ "$out2" == *"[278] fixture-packet"* ]]; then
    ok "ARM 2 --dry-run prints the plan and records nothing"
else
    bad "ARM 2 --dry-run rc=$rc2 record='$(printf '%s' "$rec2" | tr '\n' ';')'"
fi

# --- ARM 3: POSITIVE CONTROL, an explicit --drain reaches the stubs ---------
R3="$W/drain"; _sandbox "$R3"
_run "$R3" --drain --limit 1 >/dev/null; rc3=$?
n_claim="$(grep -c '^claim-ledger-node claim ' "$R3.calls")"
n_repeat="$(grep -c '^repeat ' "$R3.calls")"
if [ "$rc3" -eq 0 ] && [ "$n_claim" -eq 1 ] && [ "$n_repeat" -eq 1 ]; then
    ok "ARM 3 --drain --limit 1 claims once and launches once"
else
    bad "ARM 3 --drain --limit 1 rc=$rc3 claims=$n_claim launches=$n_repeat"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:drain-queue-bare-refuses:$pass"; exit 0; fi
echo "violation:drain-queue-bare-refuses:$pass/$total"; exit 1

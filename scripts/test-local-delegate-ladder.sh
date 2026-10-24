#!/usr/bin/env bash
# @trace order:1834-ujsf, spec:local-coding-delegation
#
# Fixture for the local-delegate outcome token and the rung aggregator
# (scripts/delegate-outcome.sh local-record, scripts/local-delegate-ladder.sh,
# scripts/lua/local-delegate-ladder.lua). Ledgers are generated: a sequence
# string of A (accepted) / R (rejected) / V (reverted), one token per outcome.
#
#   1 token grammar  local-record --dry-run prints exactly the token; a bad
#                    disposition, a colon in the model, a non-numeric
#                    tokens-avoided and a missing order are each refused
#   2 harness wiring --harness-verdict ok:...:rounds=3 gives retries=2; a
#                    refused: verdict cannot be recorded accepted, can be rejected
#   3 boundaries     20 outcomes 15A/4R/1V -> R1 promote; 14A/5R/1V (70%, 5%)
#                    -> R1; 13A/6R/1V -> R0; 15A/3R/2V (10% revert) -> R0;
#                    17A/3R -> R2; 16A/3R/1V -> R1; 19 outcomes -> none:sample
#   4 R3 / R4        positive tokens -> R3, zero or negative -> R2; 100
#                    outcomes with 2V -> R4, with 3V -> R3, 99 outcomes -> R3
#   5 demotion       20A then 2V -> R3 earned at 20, R0 and verdict=demote at 22
#   6 supersession   a later reverted token for an already-accepted order is the
#                    SAME outcome, now reverted (outcomes stays 20)
#   7 determinism    two models and two quants sort stably; two runs are identical
#   8 untouched      the existing delegate-outcome token grammar is unchanged
#
# PRE-FIX RESULT: FAILS — no local-record subcommand and no aggregator exist.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO="$ROOT/scripts/delegate-outcome.sh"
LADDER="$ROOT/scripts/local-delegate-ladder.sh"
pass=0; ran=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); ran=$((ran+1)); }
bad() { echo "FAIL: $1"; ran=$((ran+1)); }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "skip:test-local-delegate-ladder:no-plan-binary — build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
export TILLANDSIAS_PLAN_BIN="$_plan"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/local-delegate-ladder.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# rep <char> <n>
rep() { local i out=""; for ((i=0;i<$2;i++)); do out="$out$1"; done; printf '%s' "$out"; }

# gen <file> <model> <quant> <sequence> <tokens-per-accepted> [order-prefix]
gen() {
    local f="$1" m="$2" q="$3" seq="$4" tok="$5" pre="${6:-o}" i c d
    for ((i=0;i<${#seq};i++)); do
        c="${seq:i:1}"
        case "$c" in A) d=accepted ;; R) d=rejected ;; V) d=reverted ;; esac
        printf '        summary: "local-delegate outcome local-delegate:%s:%s:%s%d:%s:%s:0"\n' \
            "$m" "$q" "$pre" "$i" "$d" "$([ "$c" = A ] && echo "$tok" || echo 0)" >> "$f"
    done
}

# line <ledger-file> -> the single aggregator line
agg() { "$LADDER" --ledger "$1" 2>/dev/null | sed -n '1p'; }
expect() { # expect <label> <ledger> <substring>...
    local label="$1" f="$2" l; shift 2
    l="$(agg "$f")"
    local s
    for s in "$@"; do
        case " $l " in *" $s "*) ;; *) bad "$label: wanted '$s' in: $l"; return ;; esac
    done
    ok "$label"
}
ledger() { # ledger <name> <sequence> <tokens>
    local f="$W/$1.yaml"; : > "$f"; gen "$f" m Q5 "$2" "$3"; printf '%s' "$f"
}

# ---- 1 token grammar
t="$("$DO" local-record --model qwen3-coder-30b --quant Q5_K_M --order 1834-ujsf --disposition accepted --tokens-avoided 4000 --retries 1 --dry-run 2>&1)"
[ "$t" = "local-delegate:qwen3-coder-30b:Q5_K_M:1834-ujsf:accepted:4000:1" ] && ok "1a token grammar exact" || bad "1a token: $t"
t="$("$DO" local-record --model m --quant q --order o1 --disposition reverted --tokens-avoided -250 --dry-run 2>&1)"
[ "$t" = "local-delegate:m:q:o1:reverted:-250:0" ] && ok "1b signed tokens, default retries 0" || bad "1b: $t"
for spec in "--disposition maybe|bad disposition" "--model a:b|colon in model" "--tokens-avoided 12x|non-numeric tokens" "--order |missing order"; do
    args="${spec%%|*}"; what="${spec##*|}"
    # shellcheck disable=SC2086
    out="$("$DO" local-record --model m --quant q --order o1 --disposition accepted --dry-run $args 2>&1)"; rc=$?
    if [ "$what" = "missing order" ]; then
        out="$("$DO" local-record --model m --quant q --disposition accepted --dry-run 2>&1)"; rc=$?
    fi
    if [ $rc -ne 0 ] && ! grep -q '^local-delegate:' <<<"$out"; then ok "1c refused: $what"; else bad "1c $what accepted: $out"; fi
done

# ---- 2 harness wiring
t="$("$DO" local-record --model m --quant q --order o1 --disposition accepted --harness-verdict 'ok:local-delegate:o1:ok:rounds=3:closure=passed' --dry-run 2>&1)"
[ "$t" = "local-delegate:m:q:o1:accepted:0:2" ] && ok "2a retries from rounds" || bad "2a: $t"
out="$("$DO" local-record --model m --quant q --order o1 --disposition accepted --harness-verdict 'refused:local-delegate:o1:closure-red:rounds=2' --dry-run 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "2b red harness cannot be accepted" || bad "2b: $out"
t="$("$DO" local-record --model m --quant q --order o1 --disposition rejected --harness-verdict 'refused:local-delegate:o1:closure-red:rounds=2' --dry-run 2>&1)"
[ "$t" = "local-delegate:m:q:o1:rejected:0:0" ] && ok "2c red harness can be rejected" || bad "2c: $t"

# ---- 3 boundaries
expect "3a 15A/4R/1V -> R1 promote" "$(ledger b1 "$(rep A 15)$(rep R 4)V" 0)" rung=R1 verdict=promote outcomes=20 accepted=15 reverted=1
expect "3b 14A/5R/1V (70%, 5%) -> R1" "$(ledger b2 "$(rep A 14)$(rep R 5)V" 0)" rung=R1
expect "3c 13A/6R/1V (65%) -> R0 hold" "$(ledger b3 "$(rep A 13)$(rep R 6)V" 0)" rung=R0 verdict=hold
expect "3d 15A/3R/2V (10% revert) -> R0" "$(ledger b4 "$(rep A 15)$(rep R 3)VV" 0)" rung=R0
expect "3e 17A/3R -> R2" "$(ledger b5 "$(rep A 17)$(rep R 3)" 0)" rung=R2 verdict=promote
expect "3f 16A/3R/1V (5% revert) -> R1" "$(ledger b6 "$(rep A 16)$(rep R 3)V" 0)" rung=R1
expect "3g 19 outcomes -> none:sample" "$(ledger b7 "$(rep A 19)" 0)" rung=none:sample verdict=hold outcomes=19
expect "3h 20 outcomes of A -> R2 without tokens" "$(ledger b8 "$(rep A 20)" 0)" rung=R2

# ---- 4 R3 / R4
expect "4a positive tokens -> R3" "$(ledger c1 "$(rep A 17)$(rep R 3)" 10)" rung=R3 tokens_saved=170
expect "4b negative tokens -> R2" "$(ledger c2 "$(rep A 17)$(rep R 3)" -10)" rung=R2
expect "4c 100 outcomes, 2V -> R4" "$(ledger c3 "VV$(rep A 98)" 10)" rung=R4 outcomes=100
expect "4d 100 outcomes, 3V -> R3" "$(ledger c4 "VVV$(rep A 97)" 10)" rung=R3
expect "4e 99 outcomes -> R3" "$(ledger c5 "$(rep A 99)" 10)" rung=R3

# ---- 5 demotion
f="$(ledger d1 "$(rep A 20)" 10)"
expect "5a 20A -> R3 promote" "$f" rung=R3 verdict=promote
gen "$f" m Q5 VV 0 x
expect "5b 20A then 2V -> R0 demote" "$f" rung=R0 verdict=demote earned=R0 outcomes=22

# ---- 6 supersession
f="$(ledger e1 "$(rep A 20)" 0)"
printf '        summary: "local-delegate:m:Q5:o0:reverted:0:0"\n' >> "$f"
expect "6 later reverted supersedes accepted" "$f" outcomes=20 reverted=1 accepted=19

# ---- 7 determinism and grouping
f="$W/g.yaml"; : > "$f"
gen "$f" zeta Q4 "$(rep A 20)" 0 z; gen "$f" alpha Q8 "$(rep A 20)" 0 a; gen "$f" alpha Q4 "$(rep A 5)" 0 b
"$LADDER" --ledger "$f" > "$W/o1" 2>/dev/null; "$LADDER" --ledger "$f" > "$W/o2" 2>/dev/null
cmp -s "$W/o1" "$W/o2" && ok "7a two runs identical" || bad "7a nondeterministic"
heads="$(sed -n 's/^\(model=[^ ]* quant=[^ ]*\) .*/\1/p' "$W/o1" | tr '\n' ',')"
[ "$heads" = "model=alpha quant=Q4,model=alpha quant=Q8,model=zeta quant=Q4," ] && ok "7b sorted per model+quant" || bad "7b: $heads"
grep -q 'model=alpha quant=Q4 rung=none:sample' "$W/o1" && ok "7c small group stays none:sample" || bad "7c"

# ---- 8 existing token untouched
[ "$("$DO" token abc done)" = "delegate-outcome:abc:done" ] && ok "8 delegate-outcome token unchanged" || bad "8"

echo "summary: $pass/$ran"
[ "$pass" -eq "$ran" ] && echo "ok:local-delegate-ladder:$pass/$ran" || { echo "refused:local-delegate-ladder:$pass/$ran"; exit 1; }

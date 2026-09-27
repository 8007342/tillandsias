#!/usr/bin/env bash
# @trace order:1437-yfuh
#
# `litmus-covering-specs.sh --relay-scope` partitions the covering set into
# run and deferred (T4, plan/issues/efficiency-trims-design-2026-09-27.md).
# Six arms over a synthetic corpus pin the rules; two more over the REAL corpus
# pin that the relay catches of 2026-09-27 are still selected.
#
#   1 declared match runs whatever its size; unbound tests never appear
#   2 command match: instant/quick run, long defers as deferred:size
#   3 a non-pre-build test defers as deferred:phase, even when declared
#   4 an edited litmus file selects its own spec
#   5 an untouched path: empty set, exit 0, nothing on stderr
#   6 cap at 15 (declared first, then spec name), --all-covering lifts it,
#     and two runs are byte-identical
#
# Catches (real corpus, paths copied from the commits so a shallow clone runs):
#   f18dc0d74 (work/1428-v4tt) edited three litmus yamls and put the `&&` that
#     swallowed check-build-cache-sweep.sh's due exit into step 1. The PATH query
#     answers 0 specs for that diff (premise, asserted); relay-scope must run
#     meta-orchestration, which holds litmus:build-cache-sweep-trigger.
#   562e6281a (1432-x3ug) edited the rung-1 ground truth and left the harness
#     litmus's second copy of the 437 pin (fixed in 2b3fe5ffd); relay-scope
#     must run forge-environment-discoverability, as the full run did.
#
# PRE-FIX RESULT: the mode did not exist (usage, rc 2), so every arm fails.
# Control: deleting the self_rows call makes arm 4 and catch 1 fail.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/litmus-covering-specs.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok: $1"; }
no() { fail=$((fail + 1)); echo "FAIL: $1"; }
LT="litmus"; LT="${LT}:"   # keeps check-litmus-pin-claims off the stand-ins

mk() { # mk <file> <name> <spec> <phase> <size> <declared-path|-> <command-path|->
    {
        printf 'name: %s%s\nspec: %s\nphase: %s\nsize: %s\npreconditions:\n' "$LT" "$2" "$3" "$4" "$5"
        [ "$6" = - ] || printf '  - workspace contains %s\n' "$6"
        printf 'critical_path:\n  - step: "s"\n    command: "test -f %s"\n' "$7"
    } > "$T/tests/$1.yaml"
}
mkdir -p "$T/tests"
mk a  decl-long    s-decl  pre-build  long    lib/d.sh  -
mk b  cmd-instant  s-cmdi  pre-build  instant -         lib/c.sh
mk c  cmd-long     s-cmdl  pre-build  long    -         lib/c.sh
mk d  post         s-post  post-build instant lib/d.sh  -
mk e  orphan       s-orph  pre-build  instant lib/d.sh  -
mk f  selfish      s-self  pre-build  quick   -         none/at/all
{
    printf "version: '1.0'\nspecs:\n"
    for n in decl-long cmd-instant cmd-long post selfish; do
        printf -- '- spec_id: x\n  litmus_tests:\n  - %s%s\n' "$LT" "$n"
    done
} > "$T/bind.yaml"
rs() { TILLANDSIAS_LITMUS_TESTS_DIR="$T/tests" TILLANDSIAS_LITMUS_BINDINGS="$T/bind.yaml" \
    bash "$S" --relay-scope "$@"; }

o="$(rs --paths lib/d.sh lib/c.sh)"; rc=$?
case "$o" in *"ok:litmus-relay-scope:"*) ;; *) no "premise: relay-scope answers (rc=$rc): $o" ;; esac
TAB="$(printf '\t')"
has() { grep -qxF "$1" <<<"$o"; }

if has "run:declared:s-decl${TAB}lib/d.sh${TAB}long" && ! grep -q 's-orph' <<<"$o"; then
    ok "1 declared runs at any size; unbound never appears"
else no "1: $o"; fi

if has "run:command:s-cmdi${TAB}lib/c.sh${TAB}instant" && has "deferred:size:s-cmdl${TAB}lib/c.sh${TAB}long"; then
    ok "2 command match: instant runs, long defers by size"
else no "2: $o"; fi

if has "deferred:phase:s-post${TAB}lib/d.sh${TAB}instant" && has "ok:litmus-relay-scope:run=2 deferred=2"; then
    ok "3 non-pre-build defers by phase, even when declared"
else no "3: $o"; fi

o="$(rs --paths openspec/litmus-tests/f.yaml)"
if has "run:declared:s-self${TAB}openspec/litmus-tests/f.yaml${TAB}quick"; then
    ok "4 an edited litmus file selects its own spec"
else no "4: $o"; fi

o="$(rs --paths nothing/covers/this 2>"$T/err")"; rc=$?
if [ "$o" = "ok:litmus-relay-scope:run=0 deferred=0" ] && [ "$rc" = 0 ] && [ ! -s "$T/err" ]; then
    ok "5 untouched path: empty, rc 0, silent"
else no "5 (rc=$rc err=$(cat "$T/err")): $o"; fi

rm -f "$T"/tests/*.yaml
{ printf "version: '1.0'\nspecs:\n"; } > "$T/bind.yaml"
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17; do
    mk "k$i" "k$i" "cap-$i" pre-build instant - lib/k.sh
    printf -- '- spec_id: x\n  litmus_tests:\n  - %sk%s\n' "$LT" "$i" >> "$T/bind.yaml"
done
mk kd kd cap-zz pre-build instant lib/k.sh -
printf -- '- spec_id: x\n  litmus_tests:\n  - %skd\n' "$LT" >> "$T/bind.yaml"
o="$(rs --paths lib/k.sh)"; o2="$(rs --paths lib/k.sh)"; all="$(rs --all-covering --paths lib/k.sh)"
first="$(printf '%s\n' "$o" | head -n 1)"
if [ "$first" = "run:declared:cap-zz${TAB}lib/k.sh${TAB}instant" ] \
   && has "deferred:cap:cap-16${TAB}lib/k.sh${TAB}instant" && has "deferred:cap:cap-17${TAB}lib/k.sh${TAB}instant" \
   && has "ok:litmus-relay-scope:run=15 deferred=3" \
   && [ "$o" = "$o2" ] \
   && grep -qxF "ok:litmus-relay-scope:run=18 deferred=0" <<<"$all"; then
    ok "6 cap 15 declared-first, --all-covering lifts it, byte-identical reruns"
else no "6: $o"; fi
echo "$([ "$fail" = 0 ] && echo ok || echo fail):covering-relay-scope:${pass}/6"
syn_fail=$fail

# ── catches, real corpus ────────────────────────────────────────────────────
cpass=0; cfail=0
p1="openspec/litmus-tests/litmus-build-cache-sweep-trigger.yaml
openspec/litmus-tests/litmus-committable-branch-guard-shape.yaml
openspec/litmus-tests/litmus-plan-only-push-lane-shape.yaml"
full="$(bash "$S" $p1)"
o="$(bash "$S" --relay-scope --paths $p1)"
if [ "$full" = "ok:litmus-coverage:0-spec(s)" ] \
   && grep -q '^run:declared:meta-orchestration	' <<<"$o" \
   && grep -q "${LT}build-cache-sweep-trigger" "$ROOT/openspec/litmus-tests/litmus-build-cache-sweep-trigger.yaml"; then
    cpass=$((cpass + 1)); echo "ok: catch f18dc0d74 (1428-v4tt): path query 0 specs, relay-scope runs meta-orchestration"
else cfail=$((cfail + 1)); echo "FAIL: catch f18dc0d74: full=[$full] relay=[$o]"; fi

p2="openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml"
full="$(bash "$S" --run $p2)"
o="$(bash "$S" --relay-scope --paths $p2)"
if grep -q '^scripts/run-litmus-test.sh forge-environment-discoverability ' <<<"$full" \
   && grep -q '^run:[a-z]*:forge-environment-discoverability	' <<<"$o"; then
    cpass=$((cpass + 1)); echo "ok: catch 562e6281a (1432-x3ug): full run and relay-scope both run forge-environment-discoverability"
else cfail=$((cfail + 1)); echo "FAIL: catch 562e6281a: full=[$full] relay=[$o]"; fi
echo "$([ "$cfail" = 0 ] && echo ok || echo fail):covering-relay-scope-catches:${cpass}/2"

[ "$syn_fail" = 0 ] && [ "$cfail" = 0 ]

#!/usr/bin/env bash
# test-check-jq-callsite-ratchet.sh — order 1375-tsfu, the packet's five arms.
#
#   1  live tree: `ok:jq-callsites:<n>:floor:<f>`, n equal to `git grep -c`
#      of the guard's own published pattern, and n <= f
#   2  a new in-subset site (`x=$(jq -r .a f.json)`) in a file the floor does
#      not list: `blocked:jq-callsite-added:<file>:.a`, rc 1
#   3  a new `group_by` site: `warn:jq-callsite-added-unsupported:<file>`, rc 0
#   4  an empty population: `blocked:jq-ratchet-empty-population`, never ok
#   5  a count lowered below its floor, then --ratchet: a one-line floor diff
#
# Arms 2-5 run the REAL guard with --root over scratch trees (not git repos,
# so the guard's find branch is exercised); arm 1 runs it over this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-jq-callsite-ratchet.sh"
pass=0
fail=0
ok() { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(resolve_plan_binary 2>/dev/null)" || { echo "skip:jq-callsite-ratchet:no-plan-binary"; exit 3; }
caps="$("$PLAN" capabilities 2>/dev/null)"
case "
$caps
" in
    *"
json
"*) ;;
    *) echo "skip:jq-callsite-ratchet:plan-binary-lacks-json-verb"; exit 3 ;;
esac
export TILLANDSIAS_PLAN_BIN="$PLAN"

# Arm 1 — the live tree, pinned to a reproducible grep.
out1="$(bash "$GUARD" 2>&1)"; rc1=$?
line1="$(printf '%s\n' "$out1" | grep -E '^ok:jq-callsites:' | tail -n 1)"
n="$(printf '%s' "$line1" | cut -d: -f3)"
f="$(printf '%s' "$line1" | cut -d: -f5)"
P1="$(sed -n "s/^P1='\(.*\)'$/\1/p" "$GUARD")"
if [ "$rc1" -eq 0 ] && [ -n "$n" ] && [ "$n" -le "$f" ]; then
    # Re-derive n with git grep over the same population, the guard's own lines.
    pats="$(grep -E "^P[123]=" "$GUARD")"
    eval "$pats"
    g="$(git -C "$ROOT" grep -cE -e "$P1" -e "$P2" -e "$P3" -- 'scripts/*.sh' build.sh launch.sh 'openspec/litmus-tests/*.yaml' \
        ':!scripts/check-jq-callsite-ratchet.sh' ':!scripts/test-check-jq-callsite-ratchet.sh' | awk -F: '{s += $NF} END {print s + 0}')"
    if [ "$g" = "$n" ]; then ok "ARM 1: $line1 and git grep counts $g"; else bad "ARM 1: guard n=$n, git grep=$g"; fi
else
    bad "ARM 1: no ok line with n <= f (rc=$rc1): $out1"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/jq-ratchet.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mk_tree() {
    d="$scratch/$1"
    mkdir -p "$d/scripts/portability"
    cp "$ROOT/scripts/plan-binary-probe.sh" "$d/scripts/"
    printf '#!/bin/bash\nv=$(jq -r .x in.json)\n' > "$d/scripts/old.sh"
    printf '1 scripts/old.sh\n' > "$d/scripts/portability/jq-callsite-floor.txt"
    printf '%s\n' "$d"
}

# Arm 2 — a new in-subset site blocks, naming the file and the filter.
t2="$(mk_tree arm2)"
printf '#!/bin/bash\nx=$(jq -r .a f.json)\n' > "$t2/scripts/new.sh"
out2="$(bash "$GUARD" --root "$t2" 2>&1)"; rc2=$?
if [ "$rc2" -eq 1 ] && printf '%s\n' "$out2" | grep -qx 'blocked:jq-callsite-added:scripts/new.sh:.a'; then
    ok "ARM 2: blocked:jq-callsite-added:scripts/new.sh:.a, rc 1"
else
    bad "ARM 2: rc=$rc2: $out2"
fi

# Arm 3 — a new site outside the subset warns and passes.
t3="$(mk_tree arm3)"
printf '#!/bin/bash\njq -c '"'"'group_by(.k)'"'"' f.json\n' > "$t3/scripts/new.sh"
out3="$(bash "$GUARD" --root "$t3" 2>&1)"; rc3=$?
if [ "$rc3" -eq 0 ] && printf '%s\n' "$out3" | grep -q '^warn:jq-callsite-added-unsupported:scripts/new.sh:'; then
    ok "ARM 3: warn:jq-callsite-added-unsupported, rc 0"
else
    bad "ARM 3: rc=$rc3: $out3"
fi

# Arm 4 — nothing to count is a refusal, never an ok.
t4="$scratch/arm4"; mkdir -p "$t4/scripts/portability"
out4="$(bash "$GUARD" --root "$t4" 2>&1)"; rc4=$?
if [ "$rc4" -eq 1 ] && [ "$out4" = "blocked:jq-ratchet-empty-population" ]; then
    ok "ARM 4: blocked:jq-ratchet-empty-population, rc 1"
else
    bad "ARM 4: rc=$rc4: $out4"
fi

# Arm 5 — a migration lowers one count; --ratchet moves exactly one floor line.
t5="$(mk_tree arm5)"
printf '#!/bin/bash\na=$(jq -r .a f)\nb=$(jq -r .b f)\n' > "$t5/scripts/two.sh"
printf '1 scripts/old.sh\n2 scripts/two.sh\n' > "$t5/scripts/portability/jq-callsite-floor.txt"
bash "$GUARD" --root "$t5" --ratchet >/dev/null 2>&1
cp "$t5/scripts/portability/jq-callsite-floor.txt" "$scratch/before.txt"
printf '#!/bin/bash\na=$(tillandsias-plan json get -r .a f)\nb=$(jq -r .b f)\n' > "$t5/scripts/two.sh"
bash "$GUARD" --root "$t5" --ratchet >/dev/null 2>&1
changed="$(diff "$scratch/before.txt" "$t5/scripts/portability/jq-callsite-floor.txt" | grep -c '^>')"
if [ "$changed" -eq 1 ] && grep -qx '1 scripts/two.sh' "$t5/scripts/portability/jq-callsite-floor.txt"; then
    ok "ARM 5: --ratchet lowered scripts/two.sh 2 -> 1, a one-line diff"
else
    bad "ARM 5: changed=$changed; floor now: $(cat "$t5/scripts/portability/jq-callsite-floor.txt" | tr '\n' ' ')"
fi
# ...and never raises: adding a site then --ratchet leaves the floor at 1.
printf '#!/bin/bash\na=$(jq -r .a f)\nb=$(jq -r .b f)\n' > "$t5/scripts/two.sh"
bash "$GUARD" --root "$t5" --ratchet >/dev/null 2>&1
if grep -qx '1 scripts/two.sh' "$t5/scripts/portability/jq-callsite-floor.txt"; then
    ok "ARM 5: --ratchet never raises a floor"
else
    bad "ARM 5: --ratchet raised the floor"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'PASS: check-jq-callsite-ratchet %d/%d (1375-tsfu)\n' "$pass" "$total"
    exit 0
fi
printf 'FAIL: check-jq-callsite-ratchet %d/%d (1375-tsfu)\n' "$pass" "$total"
exit 1

#!/usr/bin/env bash
# @trace order:1247-9pr8
#
# ./build.sh --preflight asks the plan binary for its currency ONCE, up front,
# and refuses by name when it is stale, instead of letting every guard that
# resolves it refuse under its own name. Measured on yolanda 2026-09-28
# (1462-trch): four unrelated-looking refusals, no mention of the binary.
#
# The whole door takes minutes, so this fixture cuts the check out of build.sh
# between its exact-once markers and runs THAT TEXT against stub binaries
# supplied through TILLANDSIAS_PLAN_BIN (the probe's own override). A
# SCRIPT_DIR pointing at this checkout supplies the real probe.
#
#   1  stale stub     -> ONE refused:preflight:stale-plan-binary line, WHY and
#                        REMEDY lines, rc 1, and nothing after the block runs
#   2  current stub   -> no refusal; the block falls through (rc 0)
#   3  mute stub      -> an old binary that cannot answer is NOT refused
#   4  no binary      -> no refusal (TILLANDSIAS_PLAN_BIN at a missing file)
#   5  markers        -> each marker occurs exactly once, in that order
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build.sh"
pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

nb="$(grep -c 'BEGIN-STALE-PLAN-BINARY-CHECK' "$BUILD")"
ne="$(grep -c 'END-STALE-PLAN-BINARY-CHECK' "$BUILD")"
lb="$(grep -n 'BEGIN-STALE-PLAN-BINARY-CHECK' "$BUILD" | head -n 1 | cut -d: -f1)"
le="$(grep -n 'END-STALE-PLAN-BINARY-CHECK' "$BUILD" | head -n 1 | cut -d: -f1)"
if [ "$nb" = 1 ] && [ "$ne" = 1 ] && [ "$lb" -lt "$le" ]; then
    ok "arm 5: markers exactly once, in order (lines $lb..$le)"
else
    bad "arm 5: markers begin=$nb end=$ne at ${lb:-?}..${le:-?}"
    echo "violation:preflight-stale-plan-binary:$pass/$((pass+fail))"; exit 1
fi

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
{
    echo 'SCRIPT_DIR="$1"'
    sed -n "${lb},${le}p" "$BUILD"
    echo 'echo "fell-through"'
} > "$W/block.sh"

mkstub() { # name, body
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$W/$1"; chmod +x "$W/$1"
}
mkstub stale 'echo "stale:validator-surface built-from=aaaa checkout=bbbb" >&2; exit 3'
mkstub current 'echo "ok:validator-surface:bbbb"; exit 0'
mkstub mute 'exit 2'

run() { TILLANDSIAS_PLAN_BIN="$1" bash "$W/block.sh" "$ROOT" > "$W/out" 2>&1; echo $?; }

# 1
rc="$(run "$W/stale")"; out="$(cat "$W/out")"
n="$(grep -c '^refused:preflight:stale-plan-binary' "$W/out")"
if [ "$rc" = 1 ] && [ "$n" = 1 ] && grep -q 'REMEDY: cargo build --release -p tillandsias-plan' "$W/out" \
   && grep -q 'WHY:' "$W/out" && ! grep -q 'fell-through' "$W/out"; then
    ok "arm 1: a stale binary gives ONE named refusal with WHY and REMEDY, rc 1, nothing after it runs"
else
    bad "arm 1: rc=$rc refusals=$n out=[$out]"
fi
# 2
rc="$(run "$W/current")"
if [ "$rc" = 0 ] && grep -q 'fell-through' "$W/out" && ! grep -q 'refused:' "$W/out"; then
    ok "arm 2: a current binary falls through, no refusal"
else
    bad "arm 2: rc=$rc out=[$(cat "$W/out")]"
fi
# 3
rc="$(run "$W/mute")"
if [ "$rc" = 0 ] && grep -q 'fell-through' "$W/out" && ! grep -q 'refused:' "$W/out"; then
    ok "arm 3: a binary too old to answer is not refused"
else
    bad "arm 3: rc=$rc out=[$(cat "$W/out")]"
fi
# 4
rc="$(run "$W/absent-binary")"
if [ "$rc" = 0 ] && grep -q 'fell-through' "$W/out" && ! grep -q 'refused:' "$W/out"; then
    ok "arm 4: no binary, no refusal"
else
    bad "arm 4: rc=$rc out=[$(cat "$W/out")]"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:preflight-stale-plan-binary:$pass/$total"; exit 0; fi
echo "violation:preflight-stale-plan-binary:$pass/$total"; exit 1

#!/usr/bin/env bash
# @trace order:1494-kkbi, order:1247-amcu
#
# test-rank-refusal-hits.sh — the bare-refusal ranker orders by what agents
# RECORD hitting, never alphabetically and never by fixture-provoked log noise.
# Hermetic: a scratch audit file, scratch ledger dirs and a scratch log.
#
# Arms:
#   1 ORDER     exact rank by recorded hits (descending), ties by token, and a
#               token recorded zero times comes after every token with hits
#   2 PREFIX    an audit token that is a static prefix counts the run-time
#               completions recorded after it
#   3 LOGS      (negative control) a token hit only in a --logs file does NOT
#               outrank a recorded token; its hits appear in the logs= column
#   4 EMPTY     an audit with no bare sites refuses, never prints an empty rank
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/scripts/rank-refusal-hits.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/rank-hits.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/ledger" "$W/issues"
cat > "$W/audit" <<'EOF'
covered scripts/a.sh:1 refused:covered-one
bare scripts/a.sh:10 blocked:alpha-rare
bare scripts/b.sh:20 refused:beta-common
bare scripts/b.sh:30 refused:beta-common
bare scripts/c.sh:40 violation:gamma-prefix:
bare scripts/d.sh:50 blocked:zeta-never
bare scripts/e.sh:60 refused:log-only
audit:refusal-affordance:covered=1 bare=6 sites=7
EOF
# Recorded hits: beta-common 3, gamma-prefix 2 (two completions), alpha-rare 1.
printf 'summary: stopped by refused:beta-common twice: refused:beta-common\n' > "$W/ledger/one.yaml"
printf 'saw refused:beta-common and blocked:alpha-rare\n' > "$W/issues/two.md"
printf 'violation:gamma-prefix:one and violation:gamma-prefix:two\n' > "$W/ledger/three.yaml"
# The log only: many fixture-provoked hits of refused:log-only.
for i in 1 2 3 4 5 6 7 8 9; do echo "arm $i: refused:log-only (expected)"; done > "$W/gate.log"

out="$(bash "$R" --audit-file "$W/audit" --ledger "$W/ledger" --ledger "$W/issues" --logs "$W/gate.log")"; rc=$?
order="$(grep -E '^[0-9]+ ' <<<"$out" | awk '{ print $5 }' | tr '\n' ' ')"
want="refused:beta-common violation:gamma-prefix: blocked:alpha-rare blocked:zeta-never refused:log-only "
if [ "$rc" -eq 0 ] && [ "$order" = "$want" ]; then
    ok "ARM1 ranked by recorded hits, zero-hit tokens last, ties by token: $order"
else bad "ARM1 rc=$rc order='$order' want='$want'"; fi

if grep -qE '^[0-9]+ hits=3 logs=0 sites=2 refused:beta-common scripts/b.sh:20$' <<<"$out" \
   && grep -qE '^[0-9]+ hits=2 logs=0 sites=1 violation:gamma-prefix: ' <<<"$out"; then
    ok "ARM2 a static-prefix token counts its recorded run-time completions (hits=2), sites and first site reported"
else bad "ARM2 out='$(tr '\n' '|' <<<"$out")'"; fi

if grep -qE '^5 hits=0 logs=9 sites=1 refused:log-only ' <<<"$out"; then
    ok "ARM3 negative control: 9 log-only hits do not enter the rank (last, logs=9)"
else bad "ARM3 log hits leaked into the rank: '$(grep log-only <<<"$out")'"; fi

grep -v '^bare ' "$W/audit" > "$W/audit-empty"
out4="$(bash "$R" --audit-file "$W/audit-empty" --ledger "$W/ledger")"; rc4=$?
[ "$rc4" -ne 0 ] && grep -q '^blocked:rank-refusal-hits:no-bare-sites' <<<"$out4" \
    && ok "ARM4 an audit with no bare sites is refused, not an empty rank" \
    || bad "ARM4 rc=$rc4 out='$out4'"

[ "$FAIL" -eq 0 ] && { echo "PASS: rank-refusal-hits (1494-kkbi)"; exit 0; }
echo "FAILED: rank-refusal-hits (1494-kkbi)"; exit 1

#!/usr/bin/env bash
# @trace order:1367-2sbc
#
# test-claim-wip-limit.sh — a host finishes or releases before it starts more.
#
# WHY THIS EXISTS. Operator, 2026-09-23: "we have started a lot of plan work at
# the same time and now they're all incomplete". Measured 2026-09-13..23: hosts
# climbed to 10, 8 and 6 concurrent claims and filing outran closing six days
# running. set-field's claim path admitted an unbounded number of claims; it
# now refuses past packet_discipline.wip_limit, counts a --story as one unit,
# and refuses a new story while another is open.
#
# Arms (the row's verifiable_closure, in its order):
#   1 WIP LIMIT     a host holding the cap in loose claims is REFUSED another,
#                   the verdict names the held orders, and nothing is written
#   2 STORY         claims sharing --story count as one unit; a DIFFERENT story
#                   is refused while any member of the held one is in_progress
#   3 RELEASE       completing one packet admits the next claim
#   4 OVERRIDE      the refusal names --over-wip; the override is admitted and
#                   recorded as an event naming the reason and the held orders
#   5 NEGATIVE      another host's claims do not count against this host
#
# Hermetic: scratch ledgers under target/plan-scratch driven through --index,
# with a methodology file of their own so the cap is READ, as in the real tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    echo "skip:claim-wip-limit:no-validator — no runnable tillandsias-plan on this host; build one: cargo build --release -p tillandsias-plan"
    echo "claim-wip-limit: 0 passed, 0 failed (skipped)"
    exit 0
fi
PLAN="$_validator"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/claim-wip.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

mk() { # mk <dir> : six ready rows 1-aaaa .. 6-ffff and a wip_limit of 2
    local d="$1" i=0; mkdir -p "$d/plan/index.d" "$d/methodology"
    printf 'distributed_work:\n  packet_discipline:\n    wip_limit: 2\n' > "$d/methodology/distributed-work.yaml"
    echo "packets:" > "$d/plan/index.yaml"
    for o in 1-aaaa 2-bbbb 3-cccc 4-dddd 5-eeee 6-ffff; do
        i=$((i+1))
        cat >> "$d/plan/index.yaml" <<EOF
  - packet_id: fixture-row-$i
    order: $o
    status: ready
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: fixture row $i
    unscoreable: "fixture packet; not scored"
    events: []
EOF
    done
}
# Capture, never `if ! <pipeline>` (795-imz3).
run() { # run <dir> <args...> -> OUT, RC
    local d="$1"; shift
    OUT="$(env -u TILLANDSIAS_HOST_KIND "$PLAN" --index "$d/plan/index.yaml" set-field "$@" 2>&1)"; RC=$?
}
frags() { find "$1/plan/index.d" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' '; }
claim() { run "$1" "$2" status in_progress --host "${3:-hosta}" --reason fixture "${@:4}"; }

# ── ARM 1: WIP LIMIT ───────────────────────────────────────────────────────
D="$W/a"; mk "$D"
claim "$D" 1-aaaa; r1=$RC; claim "$D" 2-bbbb; r2=$RC
n_before="$(frags "$D")"
claim "$D" 3-cccc
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$RC" -ne 0 ] \
   && grep -q 'refused:set-field:wip-limit:2/2' <<<"$OUT" && grep -q '1-aaaa' <<<"$OUT" && grep -q '2-bbbb' <<<"$OUT" \
   && grep -q 'from methodology/distributed-work.yaml' <<<"$OUT" && [ "$(frags "$D")" = "$n_before" ]; then
    ok "ARM 1: at the cap (read from methodology: 2) a third loose claim is refused, naming 1-aaaa and 2-bbbb, and writes nothing"
else
    bad "ARM 1: r1=$r1 r2=$r2 rc=$RC frags=$n_before->$(frags "$D") out=$(head -1 <<<"$OUT" | cut -c1-140)"
fi

# ── ARM 2: STORY ───────────────────────────────────────────────────────────
D="$W/b"; mk "$D"
claim "$D" 1-aaaa hosta --story s-one; s1=$RC
claim "$D" 2-bbbb hosta --story s-one; s2=$RC
claim "$D" 3-cccc hosta --story s-one; s3=$RC
claim "$D" 4-dddd; l1=$RC; claim "$D" 5-eeee; l2=$RC
stamped="$(grep -l '^    story: s-one$' "$D"/plan/index.d/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
claim "$D" 6-ffff hosta --story s-two
if [ "$s1$s2$s3$l1$l2" = "00000" ] && [ "$stamped" = 3 ] && [ "$RC" -ne 0 ] \
   && grep -q 'refused:set-field:story-open:s-one' <<<"$OUT"; then
    ok "ARM 2: three claims under one --story count as one unit (two loose still admitted); a new story is refused while s-one is open"
else
    bad "ARM 2: story=$s1$s2$s3 loose=$l1$l2 stamped=$stamped rc=$RC out=$(head -1 <<<"$OUT" | cut -c1-140)"
fi

# ── ARM 3: RELEASE ─────────────────────────────────────────────────────────
D="$W/a"
sleep 1   # the completion must postdate the claim in the LWW fold
run "$D" 1-aaaa status completed --host hosta --evidence deadbeef; rc_done=$RC
claim "$D" 3-cccc
if [ "$rc_done" -eq 0 ] && [ "$RC" -eq 0 ]; then
    ok "ARM 3: completing 1-aaaa admits the claim on 3-cccc"
else
    bad "ARM 3: complete rc=$rc_done, claim rc=$RC out=$(head -1 <<<"$OUT" | cut -c1-140)"
fi

# ── ARM 4: OVERRIDE ────────────────────────────────────────────────────────
claim "$D" 4-dddd; refused_out="$OUT"; refused_rc=$RC
claim "$D" 4-dddd hosta --over-wip "operator asked for 4-dddd tonight"
rec="$(grep -l 'wip-override by hosta: operator asked for 4-dddd tonight' "$D"/plan/index.d/*.yaml 2>/dev/null | head -1)"
if [ "$refused_rc" -ne 0 ] && grep -q -- '--over-wip' <<<"$refused_out" && [ "$RC" -eq 0 ] \
   && [ -n "$rec" ] && grep -q 'wip-limit:2/2' "$rec" && grep -q '3-cccc' "$rec"; then
    ok "ARM 4: the refusal names --over-wip; the override is admitted and recorded with its reason and the held orders"
else
    bad "ARM 4: refused rc=$refused_rc, override rc=$RC, record=${rec:-none}"
fi

# ── ARM 5: NEGATIVE CONTROL — another host's claims are not this host's ─────
D="$W/c"; mk "$D"
claim "$D" 1-aaaa hostb; claim "$D" 2-bbbb hostb; claim "$D" 3-cccc hostb
claim "$D" 4-dddd hosta
if [ "$RC" -eq 0 ]; then
    ok "ARM 5: three claims held by hostb do not count against hosta"
else
    bad "ARM 5: rc=$RC out=$(head -1 <<<"$OUT" | cut -c1-140)"
fi

echo "claim-wip-limit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# @trace order:1437-khnx, spec:meta-orchestration
#
# Fixture for the tier-routing scalars `size` and `implementer_tier`
# (order 1437-khnx), over scratch ledgers driven through --index:
#
#   1. a fragment declaring size: S and implementer_tier: haiku as top-level
#      packet scalars is projected by `query --json` with both keys and values,
#      and an untagged row projects implementer_tier=opus with
#      implementer_tier_source=default (operator: "No size tags get Opus");
#   2. a fragment carrying the same two as lines inside notes: projects
#      identically (the fallback for rows filed before the scalars existed);
#   3. `set-field <order> implementer_tier sonnet` writes a scalar correction
#      the fold applies (and it beats the note);
#   4. NEGATIVE CONTROL: `check --strict-fragments` refuses
#      implementer_tier: gpt and size: XL, naming the field; set-field refuses
#      writing either.
#
# PRE-FIX RESULT: FAILS — the projection listed neither key, set-field wrote a
# field no reader saw, and any spelling was accepted.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=4
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    echo "skip:packet-tier-fields:no-validator — build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
PLAN="$_validator"
export TILLANDSIAS_PLAN_BIN="$PLAN"
command -v jq >/dev/null 2>&1 || { echo "skip:packet-tier-fields:no-jq"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/packet-tier-fields.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

mk() { # mk <dir> <fragment body: the packet's extra lines>
    local d="$1"; mkdir -p "$d/plan/index.d"
    printf 'packets: []\n' > "$d/plan/index.yaml"
    {
        printf 'packets:\n  - packet_id: a-tier-row\n    order: 1-tier\n    status: ready\n'
        printf '    kind: enhancement\n    priority: p2\n    desired_release: v0.5\n'
        printf '    pickup_role: any\n    title: a row with tier fields\n'
        printf '    unscoreable: "fixture packet; not scored"\n'
        printf '%s\n' "$2"
    } > "$d/plan/index.d/20260927t000000z-00000000-fixture.yaml"
}
proj() { # proj <dir> -> "size implementer_tier" of the fixture row
    "$PLAN" --index "$1/plan/index.yaml" query --json --limit 50 2>/dev/null \
        | jq -r '.[] | select(.packet_id == "a-tier-row") | "\(.size // "-") \(.implementer_tier // "-")"'
}

# 1 — top-level scalars.
mk "$W/a1" '    size: S
    implementer_tier: haiku'
got="$(proj "$W/a1")"
# Operator ruling 2026-09-27, "No size tags get Opus": an untagged row projects
# implementer_tier=opus, marked as defaulted, and no size.
mk "$W/a1u" '    notes: |
      no tier stated here'
gotu="$("$PLAN" --index "$W/a1u/plan/index.yaml" query --json --limit 50 2>/dev/null \
        | jq -r '.[] | select(.packet_id == "a-tier-row") | "\(.size // "-") \(.implementer_tier) \(.implementer_tier_source)"')"
if [ "$got" = "S haiku" ] && [ "$gotu" = "- opus default" ]; then
    ok "arm 1: top-level scalars project (S haiku); an untagged row projects opus/default"
else
    bad "arm 1: want 'S haiku' and '- opus default', got '$got' / '$gotu'"
fi

# 2 — the notes-line fallback projects identically.
mk "$W/a2" '    notes: |
      size: S
      implementer_tier: haiku
      Prose that follows the two lines.'
got2="$(proj "$W/a2")"
[ "$got2" = "S haiku" ] && ok "arm 2: notes-line fallback projects identically" \
    || bad "arm 2: want 'S haiku', got '$got2'"

# 3 — a set-field correction is folded and beats the note.
out3="$(env -u TILLANDSIAS_HOST_KIND "$PLAN" --index "$W/a2/plan/index.yaml" set-field 1-tier implementer_tier sonnet \
        --reason "fixture correction" 2>&1)"; rc3=$?
got3="$(proj "$W/a2")"
if [ "$rc3" -eq 0 ] && [ "$got3" = "S sonnet" ]; then
    ok "arm 3: set-field implementer_tier sonnet is folded over the note"
else
    bad "arm 3: want rc=0 and 'S sonnet', got rc=$rc3 '$got3': $out3"
fi

# 4 — NEGATIVE CONTROL: unknown vocabulary is refused, by name.
mk "$W/a4" '    size: XL
    implementer_tier: gpt'
out4="$("$PLAN" --index "$W/a4/plan/index.yaml" check --strict-fragments 2>&1)"; rc4=$?
out4s="$(env -u TILLANDSIAS_HOST_KIND "$PLAN" --index "$W/a1/plan/index.yaml" set-field 1-tier implementer_tier gpt \
         --reason "fixture" 2>&1)"; rc4s=$?
case "$out4" in
    *'refused:tier-vocabulary'*'size="XL"'*) named_size=1 ;; *) named_size=0 ;;
esac
case "$out4" in
    *'implementer_tier="gpt"'*) named_tier=1 ;; *) named_tier=0 ;;
esac
case "$out4s" in *'refused:set-field:tier-vocabulary'*) named_set=1 ;; *) named_set=0 ;; esac
if [ "$rc4" -ne 0 ] && [ "$named_size" = 1 ] && [ "$named_tier" = 1 ] \
   && [ "$rc4s" -ne 0 ] && [ "$named_set" = 1 ]; then
    ok "arm 4: check --strict-fragments and set-field refuse size=XL / implementer_tier=gpt by name"
else
    bad "arm 4: want both refusals named; check rc=$rc4: $out4 | set-field rc=$rc4s: $out4s"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:packet-tier-fields:$pass/$total"
    exit 0
fi
echo "fail:packet-tier-fields:$pass/$total"
exit 1

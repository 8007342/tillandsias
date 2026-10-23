#!/usr/bin/env bash
# @trace order:1437-khnx, order:1832-5a9z, spec:meta-orchestration
#
# Fixture for the tier-routing scalars `size` and `implementer_tier`
# (order 1437-khnx), over scratch ledgers driven through --index:
#
#   1. a fragment declaring size: S and implementer_tier: haiku as top-level
#      packet scalars is projected by `query --json` with both keys and values,
#      and an untagged row projects neither (never defaulted: the untagged=opus
#      rule is the selector's, 1437-vdz5);
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
pass=0; total=10
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
proj() { # proj <dir> -> "size implementer_tier" of the fixture row, "-" when absent
    # The plan binary's own reader, not jq (1375-tsfu ratchet): its subset has
    # no `//` or string building, so it emits ["size","tier"] and sed spells it.
    "$PLAN" --index "$1/plan/index.yaml" query --json --limit 50 2>/dev/null \
        | "$PLAN" json get -c '.[] | select(.packet_id == "a-tier-row") | [.size, .implementer_tier]' 2>/dev/null \
        | sed -e 's/null/"-"/g' -e 's/^\["//' -e 's/"\]$//' -e 's/","/ /'
}

# 1 — top-level scalars.
mk "$W/a1" '    size: S
    implementer_tier: haiku'
got="$(proj "$W/a1")"
# An untagged row projects NEITHER key: the projection never defaults them. The
# operator's "No size tags get Opus" is applied by the selector (1437-vdz5).
mk "$W/a1u" '    notes: |
      no tier stated here'
gotu="$(proj "$W/a1u")"
if [ "$got" = "S haiku" ] && [ "$gotu" = "- -" ]; then
    ok "arm 1: top-level scalars project (S haiku); an untagged row projects neither key"
else
    bad "arm 1: want 'S haiku' and '- -', got '$got' / '$gotu'"
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


# ── ORDER 1832-5a9z — `local` is a routing FLOOR below haiku ─────────────────
# @trace order:1832-5a9z
# 5. the vocabulary accepts local (set-field + check --strict-fragments) and
#    still refuses gpt.
# 6. a local caller with a reachable endpoint gets ONLY local rows (tier=local).
# 7. a local caller whose endpoint is down is demoted: tier=haiku, haiku rows.
# 8. a local caller with no local rows refuses refused:no-tier-work:model-tier=local.
# 9. a haiku caller takes haiku rows first, then drains local rows.
# 10. an unknown tier is still refused.
# PRE-FIX RESULT: arms 5-9 FAIL (local not in the vocabulary; the selector had
# no --tier at all, so `--tier local` was "unknown argument").
mk "$W/a5" '    implementer_tier: haiku'
out5="$(env -u TILLANDSIAS_HOST_KIND "$PLAN" --index "$W/a5/plan/index.yaml" set-field 1-tier implementer_tier local \
        --reason "fixture" 2>&1)"; rc5=$?
got5="$(proj "$W/a5")"
mk "$W/a5s" '    implementer_tier: local'
out5s="$("$PLAN" --index "$W/a5s/plan/index.yaml" check --strict-fragments 2>&1)"; rc5s=$?
case "$out5s" in *'refused:tier-vocabulary'*) voc5=1 ;; *) voc5=0 ;; esac
if [ "$rc5" -eq 0 ] && [ "$got5" = "- local" ] && [ "$voc5" = 0 ] && [ "$rc4s" -ne 0 ]; then
    ok "arm 5: set-field implementer_tier local is accepted and folded; strict-fragments passes it; gpt still refused"
else
    bad "arm 5: want rc=0 and '- local', no tier-vocabulary refusal, gpt refused; got rc=$rc5 '$got5' voc=$voc5 gpt_rc=$rc4s: $out5 | $out5s"
fi

# selector fixtures: a ledger of ready role-any rows, one per tier, driven
# through a plan shim; `curl` is shimmed so the endpoint probe is a stub.
sel_ledger() { # sel_ledger <file> <tier-or-"-"> ... : one ready row per tier
    local f="$1"; shift
    { printf 'plan_index:\n'
      local n=0 t
      for t in "$@"; do
          n=$((n+1))
          printf '  - packet_id: tier-sel-%s-%s\n    order: 99%s-tsel\n    status: ready\n    kind: bug\n    priority: p2\n' "$t" "$n" "$n"
          printf '    desired_release: v0.5\n    release_target: tier-sel-epic-%s\n    pickup_role: any\n' "$n"
          printf '    title: tier selector fixture %s\n    unscoreable: fixture row, never landed\n' "$t"
          [ "$t" = "-" ] || printf '    implementer_tier: %s\n' "$t"
      done; } > "$f"
}
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/curl-up";   chmod +x "$W/curl-up"
printf '#!/usr/bin/env bash\nexit 22\n' > "$W/curl-down"; chmod +x "$W/curl-down"
printf '#!/usr/bin/env bash\nexec "%s" --index "$TIER_SEL_LEDGER" "$@"\n' "$PLAN" > "$W/plan-shim.sh"; chmod +x "$W/plan-shim.sh"
sel() { # sel <ledger> <curl-shim> <args...> : prints the selector's output
    local led="$1" cs="$2"; shift 2
    mkdir -p "$W/bin-$cs"; cp "$W/$cs" "$W/bin-$cs/curl"
    TIER_SEL_LEDGER="$led" PATH="$W/bin-$cs:$PATH" TILLANDSIAS_PLAN_BIN="$W/plan-shim.sh" \
        TILLANDSIAS_HOST_TIER=general TILLANDSIAS_XBRANCH_CHECK=/bin/true \
        TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:9 \
        bash "$ROOT/scripts/select-work-batch.sh" any --budget 5 "$@" 2>&1
}
orders() { printf '%s\n' "$1" | awk -F'\t' '$1=="packet"{printf "%s ", $2}'; }

sel_ledger "$W/s1.yaml" local haiku -
out6="$(sel "$W/s1.yaml" curl-up --tier local)"
case "$out6" in *' tier=local tier_fallback=0'*) t6=1 ;; *) t6=0 ;; esac
if [ "$t6" = 1 ] && [ "$(orders "$out6")" = "991-tsel " ]; then
    ok "arm 6: local caller + reachable endpoint gets only the local row (tier=local)"
else
    bad "arm 6: want only 991-tsel with tier=local, got [$(orders "$out6")]: $(printf '%s' "$out6" | head -3)"
fi

out7="$(sel "$W/s1.yaml" curl-down --tier local)"
case "$out7" in *' tier=haiku tier_fallback=0 tier_demoted=local'*) t7=1 ;; *) t7=0 ;; esac
if [ "$t7" = 1 ] && [ "$(orders "$out7")" = "992-tsel " ]; then
    ok "arm 7: local caller + endpoint down is demoted to haiku (tier=haiku tier_demoted=local), haiku row first"
else
    bad "arm 7: want only 992-tsel with tier=haiku tier_demoted=local, got [$(orders "$out7")]: $(printf '%s' "$out7" | head -3)"
fi

sel_ledger "$W/s2.yaml" haiku sonnet -
out8="$(sel "$W/s2.yaml" curl-up --tier local)"
case "$out8" in 'refused:no-tier-work:model-tier=local'*) t8=1 ;; *) t8=0 ;; esac
[ "$t8" = 1 ] && ok "arm 8: local caller with no local rows refuses refused:no-tier-work:model-tier=local" \
    || bad "arm 8: want refused:no-tier-work:model-tier=local, got: $(printf '%s' "$out8" | head -2)"

out9a="$(sel "$W/s1.yaml" curl-up --tier haiku)"
sel_ledger "$W/s3.yaml" local sonnet -
out9b="$(sel "$W/s3.yaml" curl-up --tier haiku)"
case "$out9a" in *' tier=haiku tier_fallback=0'*) t9a=1 ;; *) t9a=0 ;; esac
case "$out9b" in *' tier=haiku tier_fallback=1'*) t9b=1 ;; *) t9b=0 ;; esac
if [ "$t9a" = 1 ] && [ "$(orders "$out9a")" = "992-tsel " ] && [ "$t9b" = 1 ] && [ "$(orders "$out9b")" = "991-tsel " ]; then
    ok "arm 9: haiku caller takes haiku rows first, then drains local rows (never sonnet or untagged)"
else
    bad "arm 9: want haiku->992 fb0 and (no haiku)->local 991 fb1, got [$(orders "$out9a")] '$t9a' / [$(orders "$out9b")] '$t9b'"
fi

out10="$(sel "$W/s1.yaml" curl-up --tier gpt)"
case "$out10" in refused:*'unknown model tier gpt'*) ok "arm 10: an unknown tier is still refused" ;; *) bad "arm 10: want refusal naming gpt, got: $(printf '%s' "$out10" | head -2)" ;; esac

if [ "$pass" -eq "$total" ]; then
    echo "ok:packet-tier-fields:$pass/$total"
    exit 0
fi
echo "fail:packet-tier-fields:$pass/$total"
exit 1

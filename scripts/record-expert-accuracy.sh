#!/usr/bin/env bash
# @trace order:917-6iwv
#
# record-expert-accuracy.sh — turn the groundtruth grade into a per-host,
# CRDT-harvestable RECORD carrying the model that produced it.
#
# WHAT WAS MISSING. The grader (`tillandsias-plan grade`) and the display line
# in cycle-metrics.sh (`expert_accuracy: pass=.. graded=.. rate=..`) have both
# existed for a while. Neither PERSISTS anything: the number is computed, printed
# into a cycle report, and lost with the transcript. So "which model is actually
# good at which task", which is the whole point of 917-6iwv, could not be asked —
# there was no series to ask it of, on any host.
#
# This writes that series. It does not re-implement grading; it runs the existing
# instrument and records the verdict WITH ITS PROVENANCE.
#
# ── WHY PROVENANCE IS NOT DECORATION ────────────────────────────────────────
#
# An accuracy number without the model that produced it is unusable for the
# comparison it exists to enable. Worse, it is actively misleading across hosts:
# two hosts running different models and different index generations produce two
# rates that look comparable and are not. Every record here therefore carries
# model id, quantisation, engine, host, index generation and corpus commit, and
# a record that cannot establish one of them writes the field as `unknown`
# RATHER THAN OMITTING IT — an absent field reads as "not applicable", an
# explicit `unknown` reads as "we did not establish this", and those are
# different claims.
#
# ── THE NEGATIVE CONTROL THIS EXISTS TO PROTECT ─────────────────────────────
#
# This codebase has SHIPPED `expert_accuracy rate=100%` in the same run as
# `verdict:attention:expert-answered-nothing-check-base-branch`, and after that
# fix reported `verdict:attention:experts-never-called` against an empty usage
# log (911-m7js lineage). 917-6iwv names a repeat a REGRESSION, not a new bug.
#
# So the rule here, and it is the one to defend hardest:
#
#   status=never-called   nothing was graded. rate is null. NOT zero, NOT 100.
#   status=partial        some engines were not exercised on this host. The rate
#                         is over GRADED cases and `skipped_engines` names what
#                         did not run, so a partial run can never be mistaken
#                         for a complete one.
#   status=graded         every declared case ran.
#
# `rate_pct` is null unless `graded > 0`. A denominator is mandatory: `graded`
# is always written, so no consumer can read a rate without seeing what it is
# over. That is precisely what `rate=100%` on an unasked host lacked.
#
# ESTIMATED VS VALIDATED. 917-6iwv asks for both, and they are not the same
# claim. `validated_*` is what the grader actually checked against the corpus
# this run — the only number with evidence behind it. `estimated_*` is reserved
# for a model's self-reported or projected confidence and is written null here,
# because nothing in this repo produces one yet. Writing null is the honest
# encoding; inventing an estimate to fill the schema would make the two columns
# indistinguishable, which defeats having two.
#
# DIFFERENT MODELS ON DIFFERENT HOSTS IS INTENDED (917-6iwv exit criterion 6).
# Nothing here normalises toward a fleet model. The record is keyed by host AND
# model, so two hosts disagreeing is representable and readable rather than a
# conflict to resolve.
#
# APPEND-ONLY JSONL, one object per line, so CRDT-style harvest across hosts is
# a concatenation and never a merge conflict.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

. "$REPO_ROOT/scripts/metrics-log-path.sh"
LOG="${TILLANDSIAS_EXPERT_ACCURACY_LOG:-$(metrics_default_log expert-accuracy.jsonl "$REPO_ROOT")}"

DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --path) printf '%s\n' "$LOG"; exit 0 ;;
        -h|--help)
            echo "usage: record-expert-accuracy.sh [--dry-run|--path]"
            echo "  appends one JSONL record of the groundtruth grade to \$LOG"
            exit 0 ;;
        *) echo "refused:unknown-argument:$a" >&2; exit 2 ;;
    esac
done

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# HOST. derive-host-identity.sh already exists and already encodes the accelerator
# shape, which is exactly what a model-comparison series needs to be read by.
# forge-expert-health.jsonl records "host":"unknown" while this helper sits in
# the same scripts/ directory; that is not repeated here.
host="$(scripts/derive-host-identity.sh 2>/dev/null | head -1)"
[ -n "$host" ] || host="unknown"

commit="$(git rev-parse HEAD 2>/dev/null)" || commit="unknown"
[ -n "$commit" ] || commit="unknown"

# ── the instrument ──────────────────────────────────────────────────────────
# Resolve the binary the same way cycle-metrics.sh does, via the shared probe —
# an ad-hoc `test -x` here reported plan_bin=absent on a host where it worked.
raw=""
src="groundtruth-all-sets"

# ── FIXTURE SEAM ────────────────────────────────────────────────────────────
# A test needs to pin the never-called and partial branches, and NEITHER can be
# provoked from outside. A stale FORGE_SPEC_INDEX_DIR / TILLANDSIAS_SPEC_INDEX_DIR
# does not pin the grader to a dead rung — it FALLS THROUGH to a working one
# (measured on lenovinha 2026-09-04: an empty override dir still graded 33/33,
# skipped=0). So the only honest way to exercise "nothing was graded" is to hand
# this script the result line directly. The fixture pins its own input, which is
# the same correction test-yaml-reader-availability took after its ls-glob input
# turned out to be supplied by the tree it was meant to be testing.
#
# This is deliberately NOT a way to fake a measurement: it substitutes the
# grader's OUTPUT LINE only, every provenance field below is still resolved for
# real, and the record is stamped `source=fixture` so no harvest can mistake one
# for a graded run.
if [ -n "${TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE:-}" ]; then
    raw="$TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE"
    src="fixture"
fi

if [ -z "$raw" ]; then
    # an ad-hoc `test -x` here reported plan_bin=absent on a host where it worked.
    . "$REPO_ROOT/scripts/plan-binary-probe.sh"
    GRADE_BIN="$(resolve_plan_binary || true)"
    if [ -z "$GRADE_BIN" ]; then
        echo "blocked:expert-accuracy:no-plan-binary" >&2
        exit 1
    fi
    gt_sets="$REPO_ROOT/openspec/litmus-tests/groundtruth"
    if [ -d "$gt_sets" ]; then
        # shellcheck disable=SC2086
        raw="$(timeout 300 "$GRADE_BIN" grade --root . "$gt_sets"/*.yaml 2>/dev/null | grep '^groundtruth-result:' | tail -1)"
    fi
    if [ -z "$raw" ]; then
        raw="$(timeout 120 "$GRADE_BIN" grade --root . 2>/dev/null | grep '^groundtruth-result:' | tail -1)"
        src="groundtruth-rung1"
    fi
fi

if [ -z "$raw" ]; then
    echo "blocked:expert-accuracy:grader-produced-no-result-line" >&2
    exit 1
fi

_f() { printf '%s' "$raw" | sed -n "s/.*$1=\([^ ]*\).*/\1/p"; }
total="$(_f total)";   [ -n "$total" ] || total=0
pass="$(_f pass)";     [ -n "$pass" ] || pass=0
fail="$(_f fail)";     [ -n "$fail" ] || fail=0
skipped="$(_f skipped)"; [ -n "$skipped" ] || skipped=0
sets="$(_f sets)";     [ -n "$sets" ] || sets=0
elapsed="$(_f elapsed_ms)"; [ -n "$elapsed" ] || elapsed=0
skipped_engines="$(_f skipped_engines)"

graded=$(( total - skipped ))
[ "$graded" -ge 0 ] || graded=0

# THE NEGATIVE CONTROL. Nothing graded is never a rate — see the header.
if [ "$graded" -eq 0 ]; then
    status="never-called"
    rate="null"
elif [ "$skipped" -gt 0 ]; then
    status="partial"
    rate="$(( pass * 100 / graded ))"
else
    status="graded"
    rate="$(( pass * 100 / graded ))"
fi

# ── provenance ──────────────────────────────────────────────────────────────
# The index generation is what makes two runs comparable; spec-index-ensure.sh
# already publishes .model/.commit/.fingerprint per generation, so this reads
# them rather than re-deriving anything.
idx_root="$(scripts/spec-index-ensure.sh --where 2>/dev/null | sed -n 's/^spec-index:root=//p' | head -1)"
idx_gen="unknown"; idx_model="unknown"; idx_commit="unknown"
if [ -n "$idx_root" ] && [ -f "$idx_root/current" ]; then
    idx_gen="$(tr -d '[:space:]' < "$idx_root/current" 2>/dev/null)"
    [ -n "$idx_gen" ] || idx_gen="unknown"
    if [ "$idx_gen" != "unknown" ] && [ -d "$idx_root/$idx_gen" ]; then
        [ -f "$idx_root/$idx_gen/.model" ]  && idx_model="$(tr -d '[:space:]' < "$idx_root/$idx_gen/.model")"
        [ -f "$idx_root/$idx_gen/.commit" ] && idx_commit="$(tr -d '[:space:]' < "$idx_root/$idx_gen/.commit")"
    fi
fi
[ -n "$idx_model" ]  || idx_model="unknown"
[ -n "$idx_commit" ] || idx_commit="unknown"

# QUANTISATION is a property of the served model, not of our config, so it is
# asked of the endpoint rather than assumed from the tag. An endpoint that will
# not say leaves `unknown` standing.
endpoint="${TILLANDSIAS_EMBED_ENDPOINT:-http://127.0.0.1:11434}"
quant="unknown"; engine="unknown"
if command -v curl >/dev/null 2>&1 && [ "$idx_model" != "unknown" ]; then
    _show="$(curl -sS -m 10 "${endpoint%/}/api/show" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$idx_model\"}" 2>/dev/null)"
    if [ -n "$_show" ] && command -v jq >/dev/null 2>&1; then
        quant="$(printf '%s' "$_show" | jq -r '.details.quantization_level // "unknown"' 2>/dev/null)"
        engine="$(printf '%s' "$_show" | jq -r '.details.family // "unknown"' 2>/dev/null)"
    fi
fi
[ -n "$quant" ]  && [ "$quant" != "null" ]  || quant="unknown"
[ -n "$engine" ] && [ "$engine" != "null" ] || engine="unknown"

# The accelerator lane actually in use, from the capability row rather than from
# the hostname — 917-n3n9 is where making this anything but `cpu` is tracked.
lane="${TILLANDSIAS_EXPERT_LANE:-cpu}"

if command -v jq >/dev/null 2>&1; then
    rec="$(jq -nc \
        --arg ts "$ts" --arg host "$host" --arg commit "$commit" \
        --arg status "$status" --arg src "$src" \
        --arg im "$idx_model" --arg ig "$idx_gen" --arg ic "$idx_commit" \
        --arg q "$quant" --arg e "$engine" --arg lane "$lane" \
        --arg se "${skipped_engines:-}" \
        --argjson pass "$pass" --argjson fail "$fail" --argjson graded "$graded" \
        --argjson total "$total" --argjson skipped "$skipped" \
        --argjson sets "$sets" --argjson elapsed "$elapsed" \
        --argjson rate "$rate" \
        '{ts:$ts, host:$host, commit:$commit, status:$status, source:$src,
          validated_pass:$pass, validated_fail:$fail,
          graded:$graded, total:$total, skipped:$skipped,
          skipped_engines:(if $se=="" then null else ($se|split(",")) end),
          validated_rate_pct:$rate,
          estimated_rate_pct:null,
          sets:$sets, elapsed_ms:$elapsed,
          model:{id:$im, quantisation:$q, engine:$e, lane:$lane},
          index:{generation:$ig, corpus_commit:$ic}}')"
else
    # jq-less hosts still get a record; the schema is identical.
    _se="null"; [ -n "${skipped_engines:-}" ] && _se="[\"${skipped_engines//,/\",\"}\"]"
    rec="{\"ts\":\"$ts\",\"host\":\"$host\",\"commit\":\"$commit\",\"status\":\"$status\",\"source\":\"$src\",\"validated_pass\":$pass,\"validated_fail\":$fail,\"graded\":$graded,\"total\":$total,\"skipped\":$skipped,\"skipped_engines\":$_se,\"validated_rate_pct\":$rate,\"estimated_rate_pct\":null,\"sets\":$sets,\"elapsed_ms\":$elapsed,\"model\":{\"id\":\"$idx_model\",\"quantisation\":\"$quant\",\"engine\":\"$engine\",\"lane\":\"$lane\"},\"index\":{\"generation\":\"$idx_gen\",\"corpus_commit\":\"$idx_commit\"}}"
fi

if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "$rec"
    echo "dry-run:not-appended:$LOG" >&2
    exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
printf '%s\n' "$rec" >> "$LOG" || { echo "blocked:expert-accuracy:append-failed:$LOG" >&2; exit 1; }

# One line on stdout, same grammar as the other check-* scripts.
if [ "$status" = "never-called" ]; then
    echo "ok:expert-accuracy-recorded:never-called graded=0 total=${total} host=${host}"
else
    echo "ok:expert-accuracy-recorded:${status} rate=${rate}% pass=${pass} graded=${graded} total=${total} skipped=${skipped} model=${idx_model} lane=${lane} host=${host}"
fi

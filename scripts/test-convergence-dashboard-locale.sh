#!/usr/bin/env bash
# @trace order:1191-vrjf
#
# The dashboard renderer's output must be BYTE-IDENTICAL whatever numeric
# locale the caller runs it under. Not merely exit 0: a comma-decimal locale
# that parses a value writes "89,0" into a file read as data and exits 0.
#
# PRE-FIX RESULT: FAILS on the comma-decimal arms — "printf: 89.8989898989899:
# nombre non valable" (rc=1) under fr_FR, measured on yoga 2026-09-14 and again
# 2026-09-26 on trunk 6f8d134dd.
#
# Premises first, so a green is about the property: (a) the C-locale render
# succeeds and shows 89.9; (b) two C renders are byte-identical, so a timestamp
# in the output cannot make the comparison meaningless. A host with no
# comma-decimal locale installed prints a NAMED skip for those arms, never a pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/scripts/update-convergence-dashboard.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/dashboard-locale.XXXXXX")"
trap 'rm -rf "$work"' EXIT
record() { printf '%s\n' '{"timestamp":"2026-09-26T11:21:12Z","version":"0.0.0.0","source_commit":"000000000000","source_namespace":"local_development","ci_run_id":"fixture","ci_phase":"pre-build","release_date":"2026-09-26T11:21:12Z","expected_total_cc":'"$2"',"actual_earned_cc":'"$3"',"residual_cc":100,"percent_closed":'"$1"',"litmus_tests_run":0,"litmus_passed":0,"litmus_failed":0,"litmus_skipped":0,"project_cc_earned":'"$3"',"project_cc_total":'"$2"',"ci_result":"FAIL","max_residual_spec":"spec:fixture","max_residual_reason":"fixture","max_residual_cc":100,"evidence_bundle_ref":"x","centicolon_projection_ref":"x","top_residual_reasons":[],"failed_checks":[],"failed_reasons":[]}' > "$work/sig.jsonl"; }
fail=0; pass=0; skip=0
render() {   # <dir> <env assignments...>
    local d="$1"; shift; mkdir -p "$d"
    env "$@" SOURCE="$work/sig.jsonl" MD_OUT="$d/md" JSON_OUT="$d/json" SUMMARY_OUT="$d/summary" \
        METRICS_SAMPLE="$work/no-such-metrics.json" TERMINAL_PREVIEW=0 \
        bash "$R" > "$d/out" 2>&1
}
same() { cmp -s "$1/md" "$2/md" && cmp -s "$1/json" "$2/json" && cmp -s "$1/summary" "$2/summary"; }
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# Two values, two failure modes. The renderer derives the percent from
# earned/total, so the case is chosen by the COUNTS: 890/990 is fractional and
# is REFUSED under a comma locale (loud, rc=1); 900/1000 is 90 exactly, which
# PARSES and would render "90,0" (quiet, rc=0) — the one only byte identity
# catches.
for case in "89.8989898989899 990 890 89\.9" "90 1000 900 90\.0"; do
set -- $case; pct_in="$1"; want="$4"
record "$1" "$2" "$3"
work_run="$work/run-$pct_in"; mkdir -p "$work_run"
render "$work_run/c1" LC_ALL=C; rc1=$?
render "$work_run/c2" LC_ALL=C
if [ "$rc1" != 0 ] || ! grep -q "$want" "$work_run/c1/md"; then
    bad "[$pct_in] premise: the C-locale render did not succeed with ${want//\\/} (rc=$rc1): $(tail -1 "$work_run/c1/out")"
elif ! same "$work_run/c1" "$work_run/c2"; then
    bad "[$pct_in] premise: two C-locale renders differ, so byte identity cannot be asserted"
else
    ok "[$pct_in] premise: C render succeeds, shows ${want//\\/}, and is reproducible"
    loc=""
    for c in fr_FR.UTF-8 fr_FR.utf8 de_DE.UTF-8 de_DE.utf8; do
        case "
$(locale -a 2>/dev/null)
" in *"
$c
"*) loc="$c"; break ;; esac
    done
    if [ -z "$loc" ]; then
        skip=$((skip + 1)); echo "skip [$pct_in] no comma-decimal locale installed (fr_FR/de_DE): the locale arms did not run"
    else
        for mode in "LC_ALL=$loc" "LC_NUMERIC=$loc"; do
            d="$work_run/$(printf '%s' "$mode" | tr '=.@' '___')"
            render "$d" -u LC_ALL $mode; rc=$?
            if [ "$rc" != 0 ]; then bad "[$pct_in] under $mode the renderer exits $rc: $(tail -1 "$d/out")"
            elif ! same "$work_run/c1" "$d"; then bad "[$pct_in] under $mode the output differs from C (e.g. $(grep -oE '(89|90),[0-9]' "$d/md" | head -1))"
            else ok "[$pct_in] under $mode the output is byte-identical to C"; fi
        done
    fi
fi
done
if [ "$fail" = 0 ]; then echo "ok:convergence-dashboard-locale:$pass arms (skipped=$skip)"; exit 0; fi
echo "FAIL:convergence-dashboard-locale:$fail failed"; exit 1

#!/usr/bin/env bash
# @trace order:1395-88tp
#
# centicolon-grade.sh — run the CentiColon pipeline end to end and print one
# verdict line: extractor (1395-n7qd, Cacheable) -> static grader (Cacheable)
# -> results stream -> observed grader (Observing).
#
#   scripts/centicolon-grade.sh            # grade this checkout
#   TILLANDSIAS_REPO_ROOT=<dir> scripts/centicolon-grade.sh   # grade another corpus
#
# Inputs the predicates cannot gather themselves (the Cacheable class has no
# fs.list and fs.read is rooted at the repository) are prepared here:
#   * the spec directory list and the litmus file list, passed as arguments
#   * the per-test results stream, copied from the timing log
#     (TILLANDSIAS_TIMING_LOG, else `tillandsias-plan metrics-log-path`) into
#     <out>/results.jsonl — only records that carry a digest
# Outputs land in <out> = $TILLANDSIAS_CENTICOLON_DIR (default target/centicolon
# under the graded root): obligations.json, static.json, results.jsonl,
# grade.json.
#
# Verdict grammar (one line on stdout, last):
#   ok:centicolon-grade:R=<n> satisfied=<n> denominator=<n> declared=<n> traced=<n> positively_tested=<n> records=<n>
#   blocked:centicolon-grade:<why>          (no binary, extractor refused, no output)
# Static refusals (unresolved requirement keys, zero resolved keys) are printed
# as warn:centicolon-grade:<refusal> lines BEFORE the verdict: the grade is
# still computed, because an advisory R must be printable while they stand.
set -uo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TILLANDSIAS_REPO_ROOT:-$(cd "$SCRIPTS/.." && pwd)}"
cd "$ROOT" || { echo "blocked:centicolon-grade:no-root:$ROOT"; exit 1; }
OUT_REL="${TILLANDSIAS_CENTICOLON_DIR:-target/centicolon}"
mkdir -p "$OUT_REL" || { echo "blocked:centicolon-grade:cannot-create:$OUT_REL"; exit 1; }

. "$SCRIPTS/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then
    echo "blocked:centicolon-grade:no-runnable-plan-binary"; exit 1
fi
if ! grep -qx 'predicate' <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "blocked:centicolon-grade:plan-binary-lacks-predicate-verb:$PLAN"; exit 1
fi

# pred <name> <class> <arg> <prefix> <outfile> — run one predicate, write its
# JSON payload to <outfile>, echo its verdict lines; returns the predicate's rc.
pred() {
    local rc=0 err
    err="$(TILLANDSIAS_REPO_ROOT="$ROOT" "$PLAN" predicate "$SCRIPTS/lua/$1.lua" --class "$2" --arg "$3" 2>&1 >/dev/null)" || rc=$?
    err="$(sed 's/^\[lua-predicate\] //' <<<"$err")"
    sed -n "s/^$4://p" <<<"$err" >"$5"
    grep -E '^(ok|refused|blocked):' <<<"$err" || true
    return "$rc"
}

dirs="$(cd openspec/specs 2>/dev/null && for d in */; do printf '%s,' "${d%/}"; done)"
ext_v="$(pred centicolon-extract cacheable "$dirs" centicolon-extract "$OUT_REL/obligations.json")"
if ! grep -q '^ok:' <<<"$ext_v" || [ ! -s "$OUT_REL/obligations.json" ]; then
    echo "blocked:centicolon-grade:extractor:$(head -1 <<<"$ext_v")"; exit 1
fi

files="$(for f in openspec/litmus-tests/*.yaml; do [ -f "$f" ] && printf '%s,' "$f"; done)"
st_v="$(pred centicolon-grade-static cacheable "$OUT_REL/obligations.json|$files" centicolon-grade-static "$OUT_REL/static.json")"
[ -s "$OUT_REL/static.json" ] || { echo "blocked:centicolon-grade:static:$(head -1 <<<"$st_v")"; exit 1; }
while IFS= read -r l; do
    case "$l" in refused:centicolon-grade-static:*) echo "warn:centicolon-grade:${l#refused:centicolon-grade-static:}" ;; esac
done <<<"$st_v"

log="${TILLANDSIAS_TIMING_LOG:-$("$PLAN" metrics-log-path tillandsias-timing.jsonl "$ROOT" 2>/dev/null)}"
: >"$OUT_REL/results.jsonl"
if [ -n "$log" ] && [ -f "$log" ]; then
    grep -F '"digest":"' "$log" >"$OUT_REL/results.jsonl" 2>/dev/null || true
fi

ob_v="$(pred centicolon-grade-observed observing "$OUT_REL/static.json|$OUT_REL/results.jsonl" centicolon-grade-observed "$OUT_REL/grade.json")"
[ -s "$OUT_REL/grade.json" ] || { echo "blocked:centicolon-grade:observed:$(head -1 <<<"$ob_v")"; exit 1; }
v="$(grep -m1 '^ok:centicolon-grade-observed:' <<<"$ob_v")"
[ -n "$v" ] || { echo "blocked:centicolon-grade:observed-no-verdict"; exit 1; }
echo "ok:centicolon-grade:${v#ok:centicolon-grade-observed:}"

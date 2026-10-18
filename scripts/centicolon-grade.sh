#!/usr/bin/env bash
# @trace order:1395-88tp, order:1572-nqx5, order:1247-amcu
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
#   unmeasured:centicolon-grade:<same fields> reason=<why>   (exit 0; 1670-gcwu)
#       the grade was computed but measures nothing: zero requirement keys
#       resolved over a non-empty litmus corpus, so R = denominator by
#       construction. grade.json carries measured:false and unmeasured_reason.
#   blocked:centicolon-grade:<why>          (no binary, extractor refused, no output)
#       each followed on stderr by `  why:` / `  remedy:` lines (1247-amcu);
#       a stage's full stderr is kept in <out>/<predicate>.stderr (1572-nqx5)
# Static refusals (unresolved requirement keys, zero resolved keys) are printed
# as warn:centicolon-grade:<refusal> lines BEFORE the verdict: the grade is
# still computed, because an advisory R must be printable while they stand.
set -uo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TILLANDSIAS_REPO_ROOT:-$(cd "$SCRIPTS/.." && pwd)}"

# 1247-amcu: every blocked verdict says why it refused and what clears it, on
# stderr, so the one stdout verdict line stays machine-readable.
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }

# The binary is resolved from THIS checkout (the scripts' own root), never from
# the graded root, and made absolute before the cd below.
. "$SCRIPTS/plan-binary-probe.sh"
if ! PLAN="$(cd "$SCRIPTS/.." && resolve_plan_binary)"; then
    echo "blocked:centicolon-grade:no-runnable-plan-binary"
    _afford "the grader runs its stages as tillandsias-plan predicates, and no runnable tillandsias-plan was found (TILLANDSIAS_PLAN_BIN, target/{release,debug}, PATH)" \
        "cargo build --release -p tillandsias-plan in $(cd "$SCRIPTS/.." && pwd), or set TILLANDSIAS_PLAN_BIN to an existing binary"
    exit 1
fi
case "$PLAN" in /*) ;; *) PLAN="$(cd "$SCRIPTS/.." && cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")" ;; esac

cd "$ROOT" || {
    echo "blocked:centicolon-grade:no-root:$ROOT"
    _afford "the corpus to grade is TILLANDSIAS_REPO_ROOT (default: this checkout), and that directory cannot be entered" \
        "point TILLANDSIAS_REPO_ROOT at an existing checkout, or unset it to grade this one"
    exit 1
}
ROOT="$(pwd)"
OUT_REL="${TILLANDSIAS_CENTICOLON_DIR:-target/centicolon}"
# 1572-nqx5: the predicates' fs.read is rooted at the graded repository, so an
# output dir outside it was written by the shell redirects and then refused by
# the static grader's read, which reached the caller as "blocked:...:static:"
# with nothing after the colon. Refuse it here, before anything is written.
case "$OUT_REL" in
    "$ROOT") OUT_REL=. ;;
    "$ROOT"/*) OUT_REL="${OUT_REL#"$ROOT"/}" ;;
    /*)
        echo "blocked:centicolon-grade:out-dir-outside-root:$OUT_REL"
        _afford "the stages read each other's output through fs.read, which refuses any path outside the graded root $ROOT" \
            "TILLANDSIAS_CENTICOLON_DIR=target/centicolon (or any path under $ROOT, relative or absolute), or unset it"
        exit 1 ;;
esac
mkdir -p "$OUT_REL" || {
    echo "blocked:centicolon-grade:cannot-create:$OUT_REL"
    _afford "the output dir (TILLANDSIAS_CENTICOLON_DIR, default target/centicolon) could not be created under $ROOT" \
        "make $ROOT/$OUT_REL creatable (a file at that path, or a read-only tree, blocks it), or set TILLANDSIAS_CENTICOLON_DIR to another path under $ROOT"
    exit 1
}
if ! grep -qx 'predicate' <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "blocked:centicolon-grade:plan-binary-lacks-predicate-verb:$PLAN"
    _afford "$PLAN was built from sources older than the predicate verb the stages run under" \
        "cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN to a current binary"
    exit 1
fi

# pred <name> <class> <arg> <prefix> <outfile> — run one predicate, write its
# JSON payload to <outfile>, echo its verdict lines; returns the predicate's rc.
# Its whole stderr is kept in <out>/<name>.stderr. 1572-nqx5: a predicate that
# dies (a Lua runtime error) prints no verdict line, and keeping only verdict
# lines dropped the one line that named the cause; that line is now echoed as
# `error:<first line>` so the caller's blocked reason carries it.
pred() {
    local rc=0 err verdicts
    err="$(TILLANDSIAS_REPO_ROOT="$ROOT" "$PLAN" predicate "$SCRIPTS/lua/$1.lua" --class "$2" --arg "$3" 2>&1 >/dev/null)" || rc=$?
    err="$(sed 's/^\[lua-predicate\] //' <<<"$err")"
    printf '%s\n' "$err" >"$OUT_REL/$1.stderr"
    sed -n "s/^$4://p" <<<"$err" >"$5"
    verdicts="$(grep -E '^(ok|unmeasured|refused|blocked):' <<<"$err")"
    if [ -n "$verdicts" ]; then
        printf '%s\n' "$verdicts"
    elif [ "$rc" -ne 0 ]; then
        printf 'error:%s\n' "$(grep -m1 . <<<"$err")"
    fi
    return "$rc"
}
# stage_blocked <stage> <predicate> <verdict lines> — a stage left no output.
stage_blocked() {
    echo "blocked:centicolon-grade:$1:$(head -1 <<<"$3")"
    _afford "the $1 stage (scripts/lua/$2.lua) wrote no output; the reason after '$1:' is its first verdict or error line" \
        "read its full stderr in $OUT_REL/$2.stderr, fix what it names, and re-run"
    exit 1
}

dirs="$(cd openspec/specs 2>/dev/null && for d in */; do printf '%s,' "${d%/}"; done)"
ext_v="$(pred centicolon-extract cacheable "$dirs" centicolon-extract "$OUT_REL/obligations.json")"
if ! grep -q '^ok:' <<<"$ext_v" || [ ! -s "$OUT_REL/obligations.json" ]; then
    stage_blocked extractor centicolon-extract "$ext_v"
fi

files="$(for f in openspec/litmus-tests/*.yaml; do [ -f "$f" ] && printf '%s,' "$f"; done)"
st_v="$(pred centicolon-grade-static cacheable "$OUT_REL/obligations.json|$files" centicolon-grade-static "$OUT_REL/static.json")"
[ -s "$OUT_REL/static.json" ] || stage_blocked static centicolon-grade-static "$st_v"
while IFS= read -r l; do
    case "$l" in refused:centicolon-grade-static:*) echo "warn:centicolon-grade:${l#refused:centicolon-grade-static:}" ;; esac
done <<<"$st_v"

log="${TILLANDSIAS_TIMING_LOG:-$("$PLAN" metrics-log-path tillandsias-timing.jsonl "$ROOT" 2>/dev/null)}"
: >"$OUT_REL/results.jsonl"
if [ -n "$log" ] && [ -f "$log" ]; then
    grep -F '"digest":"' "$log" >"$OUT_REL/results.jsonl" 2>/dev/null || true
fi

ob_v="$(pred centicolon-grade-observed observing "$OUT_REL/static.json|$OUT_REL/results.jsonl" centicolon-grade-observed "$OUT_REL/grade.json")"
[ -s "$OUT_REL/grade.json" ] || stage_blocked observed centicolon-grade-observed "$ob_v"
v="$(grep -m1 -E '^(ok|unmeasured):centicolon-grade-observed:' <<<"$ob_v")"
[ -n "$v" ] || {
    echo "blocked:centicolon-grade:observed-no-verdict"
    _afford "the observed grader wrote grade.json but printed neither ok: nor unmeasured:, so there is no grade to report" \
        "read $OUT_REL/centicolon-grade-observed.stderr; the grader's verdict contract is in scripts/lua/centicolon-grade-observed.lua"
    exit 1
}
echo "${v%%:*}:centicolon-grade:${v#*:centicolon-grade-observed:}"

#!/usr/bin/env bash
# measure-margin-bands.sh — the margin + lexical-overlap refusal instrument.
# @trace order:1820-m2kq
#
# Embeds a labelled question set against ONE index generation through
# `tillandsias-plan spec-refusal-calibrate` (one index load, the same
# spec::apply_refusal_rule the pipeline and spec-floor run), then reduces the
# rows to the confusion that decides adoption:
#
#   in   answered      (1 - in-corpus false-refusal rate)
#   near refused       (plausible-but-unanswerable, correctly refused)
#   far  refused       (off-topic, correctly refused)
#
# for the FLOOR-ONLY rule (best < TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR) and for
# the CURRENT rule (the floor, then TILLANDSIAS_RETRIEVE_MARGIN_FLOOR on
# best - median(top-k), then TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR on query-term
# overlap with the best chunk). --grid also sweeps margin x lexical floors on
# top of the floor-only verdict, so a new (embedder, corpus) regime re-picks
# them from data rather than inheriting these.
#
# The default question set is the RELABELLED-561 ground truth (in=458 near=33
# far=70), read straight from the baseline TSV — see apply-relabelled-561.sh
# for why questions-wide-579.jsonl's labels must not be scored as truth.
#
#   scripts/refusal-calibration/measure-margin-bands.sh \
#       --index-dir "$IDX" [--questions F.tsv|F.jsonl] [--k 8] [--grid] \
#       [--raw OUT.tsv]
#   scripts/refusal-calibration/measure-margin-bands.sh --from-raw OUT.tsv [--grid]
#
# Last line: ok:margin-bands:<rows>  |  blocked:margin-bands:<reason>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../plan-binary-probe.sh"

_afford() { printf "  why: %s\n  remedy: %s\n" "$1" "$2" >&2; }
# One refusal grammar: the verdict on stdout, why/remedy on stderr.
_block() {
    echo "blocked:margin-bands:$1"
    _afford "$2" "$3"
    exit "${4:-2}"
}

INDEX_DIR=""
QFILE="$HERE/results-relabelled-561-nomic-20260829-macuahuitl.tsv"
K=8
GRID=0
RAW=""
FROM_RAW=""

while [ $# -gt 0 ]; do
    case "$1" in
        --index-dir) INDEX_DIR="$2"; shift 2 ;;
        --questions) QFILE="$2"; shift 2 ;;
        --k) K="$2"; shift 2 ;;
        --grid) GRID=1; shift ;;
        --raw) RAW="$2"; shift 2 ;;
        --from-raw) FROM_RAW="$2"; shift 2 ;;
        *) _block "unknown-argument:$1" "only the flags in this script's header are accepted" "see the usage block at the top of measure-margin-bands.sh" ;;
    esac
done

if [ -n "$FROM_RAW" ]; then
    [ -s "$FROM_RAW" ] || _block "no-such-raw:$FROM_RAW" "--from-raw re-reduces an existing spec-refusal-calibrate TSV and that file is missing or empty" "pass the --raw file a previous measurement wrote"
    ROWS="$FROM_RAW"
else
    [ -n "$INDEX_DIR" ] || _block index-dir-required "a measurement needs ONE index generation to embed against" "pass --index-dir <generation dir holding chunks.jsonl + vectors.jsonl>"
    [ -d "$INDEX_DIR" ] || _block "no-such-index:$INDEX_DIR" "the index generation directory does not exist (generations are garbage-collected on rebuild)" "copy the current generation somewhere stable and pass that path"
    [ -s "$QFILE" ] || _block "no-such-questions:$QFILE" "the labelled question set is missing or empty" "pass --questions <JSONL {band,corpus,q} or a measure-bands TSV>"
    if ! PLAN="$(resolve_plan_binary)"; then
        _block no-runnable-plan-binary "no tillandsias-plan binary runs on this host" "cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN"
    fi
    if ! plan_binary_has "$PLAN" spec-refusal-calibrate; then
        _block "stale-plan-binary:$PLAN" "the resolved binary predates the spec-refusal-calibrate arm (order 1820-m2kq)" "cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN to a fresh build"
    fi
    if [ -n "$RAW" ]; then
        ROWS="$RAW"
    else
        ROWS="$(mktemp "${TMPDIR:-/tmp}/margin-bands.XXXXXX")"
        trap 'rm -f "$ROWS"' EXIT
    fi
    # A question that fails to embed is reported on stderr and NOT scored —
    # an unembedded question scoring 0.0 would land in the refuse band and
    # read as a success.
    if ! "$PLAN" spec-refusal-calibrate --index-dir "$INDEX_DIR" --questions "$QFILE" --k "$K" >"$ROWS"; then
        _block calibrate-failed "spec-refusal-calibrate exited non-zero (its own error is on stderr above)" "fix what it names: usually an inconsistent index or an unreachable TILLANDSIAS_EMBED_ENDPOINT" 1
    fi
fi

LC_ALL=C awk -F'\t' -v grid="$GRID" '
function row(label, a) {
    printf "  %-10s in answered %3d/%-3d  near refused %2d/%-2d  far refused %2d/%-2d  out-of-corpus answered %d\n", \
        label, a["in"], N["in"], N["near"] - a["near"], N["near"], N["far"] - a["far"], N["far"], a["near"] + a["far"]
}
NR == 1 { next }
$1 == "" { next }
{
    n++; band[n] = $1
    floor_ref[n] = ($10 != "answer")
    # An absent signal (top-k too short / no content terms) abstains: it can
    # never refuse, so it reads as +inf here.
    mar[n] = ($5 == "") ? 9 : $5 + 0
    lex[n] = ($6 == "") ? 9 : $6 + 0
    N[$1]++
    if ($10 == "answer") fa[$1]++
    if ($11 == "answer") na[$1]++
    else why[$1 "\t" $11]++
}
END {
    print "CONFUSION (refuse = Unsupported)"
    row("floor-only", fa)
    row("current", na)
    print "CURRENT RULE — which signal refused, per band"
    for (k in why) { split(k, p, "\t"); printf "  %-5s %-28s %d\n", p[1], p[2], why[k] }
    if (grid) {
        print "GRID (refuse if floor-only refused OR margin<M OR lexical<L)"
        for (mi = 0; mi <= 10; mi++) {
            M = mi * 0.005
            for (li = 0; li <= 8; li++) {
                L = li * 0.05
                ai = 0; rn = 0; rf = 0
                for (i = 1; i <= n; i++) {
                    r = floor_ref[i] || mar[i] < M || lex[i] < L
                    if (band[i] == "in" && !r) ai++
                    if (band[i] == "near" && r) rn++
                    if (band[i] == "far" && r) rf++
                }
                printf "  M=%.3f L=%.2f  in_ans=%d near_ref=%d far_ref=%d out_answered=%d\n", \
                    M, L, ai, rn, rf, (N["near"] - rn) + (N["far"] - rf)
            }
        }
    }
    printf "ok:margin-bands:%d\n", n
}
' "$ROWS"

#!/usr/bin/env bash
# apply-relabelled-561.sh — project a wide-579 measurement onto the relabelled
# 561-question ground truth, so results from different embedders are comparable.
#
# WHY THIS EXISTS, AND WHY IT IS A SCRIPT RATHER THAN A REMEMBERED PROCEDURE.
#
# The question set has TWO label generations and they disagree violently:
#
#     questions-wide-579.jsonl        near=243  far=70  in=266
#     the relabelled ground truth     near=33   far=70  in=458
#
# 86% of the original near-miss labels were WRONG (824-6qxh): they were written
# believing a cross-corpus question counted as a near-miss, when retrieval is
# global and such questions are simply in-corpus. Every conclusion drawn on the
# 579 labels is drawn on that error.
#
# The relabelling was performed ONCE, by hand, and recorded only as its OUTPUT
# (results-relabelled-561-*.tsv) plus two prose files. So the next person to
# measure a new embedder — me, today, with qwen3-embedding:4b — reaches for
# questions-wide-579.jsonl because it is the only question FILE, produces a
# result carrying the discredited labels, and compares it against baselines
# carrying the corrected ones. I started exactly that run before noticing the
# band composition did not match. An unrepeatable data-cleaning step is a trap
# that rearms itself every time someone new does the obvious thing.
#
# THE MAPPING IS TAKEN FROM THE BASELINE ITSELF, not re-derived from the prose
# files. results-relabelled-561-nomic.tsv already encodes, for every surviving
# question, its corrected band. Joining on question text therefore guarantees
# identical labels and an identical question set by construction, rather than by
# my reading of relabel-overturned-13.txt agreeing with the original author's.
#
# SELF-CHECK: --verify projects results-wide-579-nomic.tsv through this script
# and requires the output to reproduce results-relabelled-561-nomic.tsv exactly.
# If the reconstruction is wrong, that comparison fails.
#
# Output grammar (last line):
#   ok:relabelled:<rows-in>:<rows-out>:<dropped>
#   ok:relabel-verify:reproduces-baseline
#   blocked:relabel:<reason>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="$HERE/results-relabelled-561-nomic.tsv"
IN=""
OUT=""
VERIFY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --in)      IN="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --verify)  VERIFY=1; shift ;;
        --help|-h) echo "usage: apply-relabelled-561.sh --in WIDE.tsv --out RELABELLED.tsv"
                   echo "       apply-relabelled-561.sh --verify"
                   exit 0 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done

[ -f "$BASELINE" ] || { echo "blocked:relabel:no-baseline"; exit 1; }

project() {
    # $1 = wide tsv, $2 = out tsv. Join on the question column (8) and take the
    # band (column 1) from the baseline. A question absent from the baseline was
    # dropped in the relabelling and must be dropped here too.
    awk -F'\t' -v OFS='\t' -v base="$BASELINE" '
        BEGIN {
            while ((getline line < base) > 0) {
                n = split(line, f, "\t")
                if (f[1] == "band") continue          # header
                if (f[8] == "") continue              # blank row in the baseline
                band[f[8]] = f[1]
            }
            close(base)
        }
        NR == 1 { print; next }
        {
            if ($8 == "") next
            if (!($8 in band)) { dropped++; next }
            $1 = band[$8]
            print
            kept++
        }
        END { printf "%d\t%d\n", kept, dropped > "/dev/stderr" }
    ' "$1" > "$2" 2>/tmp/relabel-counts.$$
    read -r kept dropped < /tmp/relabel-counts.$$
    rm -f /tmp/relabel-counts.$$
    printf '%s %s\n' "$kept" "$dropped"
}

if [ "$VERIFY" -eq 1 ]; then
    src="$HERE/results-wide-579-nomic.tsv"
    [ -f "$src" ] || { echo "blocked:relabel:no-wide-nomic-to-verify-against"; exit 1; }
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    read -r kept dropped <<<"$(project "$src" "$tmp")"
    echo "projected $src -> kept=$kept dropped=$dropped" >&2
    # Compare on the fields the relabelling can affect. Scores must be identical
    # (same measurement) and bands must match the baseline.
    if diff <(sort "$tmp") <(grep -v '^[[:space:]]*$' "$BASELINE" | sort) > /tmp/relabel-diff.$$ 2>&1; then
        rm -f /tmp/relabel-diff.$$
        echo "ok:relabel-verify:reproduces-baseline"
        exit 0
    fi
    echo "reconstruction does NOT reproduce the baseline; first differences:" >&2
    head -8 /tmp/relabel-diff.$$ >&2
    rm -f /tmp/relabel-diff.$$
    echo "blocked:relabel:verify-mismatch"
    exit 1
fi

[ -n "$IN" ] && [ -f "$IN" ] || { echo "blocked:relabel:no-input"; exit 1; }
[ -n "$OUT" ] || { echo "blocked:relabel:no-output"; exit 1; }
read -r kept dropped <<<"$(project "$IN" "$OUT")"
echo "ok:relabelled:$(( $(wc -l < "$IN") - 1 )):$kept:$dropped"

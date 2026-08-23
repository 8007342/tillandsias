#!/usr/bin/env bash
# analyze-bands.sh — turn a measure-bands TSV into a separability verdict.
#
# The question is never "what is the average score". It is: IS THERE A CUTOFF
# that admits every in-corpus question and refuses every near-miss? That is a
# comparison of the in-corpus FLOOR against the near-miss CEILING, and it is
# answered per corpus as well as globally, because the two can disagree — the
# global bands overlapped by 0.0072 on 2026-08-22 while every per-corpus pair
# still separated.
#
# Also reports the MARGIN (top1-top2) bands, because "use the margin instead"
# is the obvious next idea and it needs the same falsification.
set -uo pipefail

TSV="${1:-/dev/stdin}"

awk -F'\t' '
NR == 1 { next }
$1 == "" { next }
{
    band = $1; corpus = $2; t1 = $3 + 0; m = $5 + 0;
    n[band]++;
    if (!(band in lo) || t1 < lo[band]) lo[band] = t1;
    if (!(band in hi) || t1 > hi[band]) hi[band] = t1;
    sum[band] += t1;
    if (!(band in mlo) || m < mlo[band]) mlo[band] = m;
    if (!(band in mhi) || m > mhi[band]) mhi[band] = m;

    ck = corpus "\t" band;
    cn[ck]++;
    if (!(ck in clo) || t1 < clo[ck]) clo[ck] = t1;
    if (!(ck in chi) || t1 > chi[ck]) chi[ck] = t1;
    corpora[corpus] = 1;
}
END {
    printf "GLOBAL BANDS (top-1 cosine)\n";
    printf "  %-6s %5s  %-9s %-9s %-9s\n", "band", "n", "floor", "mean", "ceiling";
    split("in near far", order, " ");
    for (i = 1; i <= 3; i++) {
        b = order[i];
        if (!(b in n)) continue;
        printf "  %-6s %5d  %-9.4f %-9.4f %-9.4f\n", b, n[b], lo[b], sum[b]/n[b], hi[b];
    }
    printf "\n";
    if (("in" in n) && ("near" in n)) {
        gap = lo["in"] - hi["near"];
        printf "  SEPARABLE BY ONE GLOBAL THRESHOLD? ";
        if (gap > 0)
            printf "YES — gap %.4f (any cutoff in (%.4f, %.4f))\n", gap, hi["near"], lo["in"];
        else
            printf "NO — bands OVERLAP by %.4f (in-floor %.4f < near-ceiling %.4f)\n", -gap, lo["in"], hi["near"];
    }
    printf "\n";

    if (("in" in mlo) && ("near" in mhi)) {
        printf "MARGIN BANDS (top1 - top2)\n";
        printf "  in    floor %.4f  ceiling %.4f\n", mlo["in"], mhi["in"];
        printf "  near  floor %.4f  ceiling %.4f\n", mlo["near"], mhi["near"];
        mgap = mlo["in"] - mhi["near"];
        printf "  SEPARABLE BY MARGIN? ";
        if (mgap > 0) printf "YES — gap %.4f\n", mgap;
        else printf "NO — overlap %.4f\n", -mgap;
        printf "\n";
    }

    printf "PER-CORPUS (top-1 cosine)\n";
    printf "  %-12s %5s %-9s | %5s %-9s | %s\n", "corpus", "n_in", "in-floor", "n_nr", "nr-ceil", "verdict";
    for (c in corpora) {
        ik = c "\t" "in"; nk = c "\t" "near";
        if (!(ik in cn) || !(nk in cn)) continue;
        g = clo[ik] - chi[nk];
        printf "  %-12s %5d %-9.4f | %5d %-9.4f | %s %.4f\n", \
            c, cn[ik], clo[ik], cn[nk], chi[nk], (g > 0 ? "SEPARATES by" : "OVERLAPS by"), (g > 0 ? g : -g);
    }
}
' "$TSV"

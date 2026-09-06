#!/usr/bin/env bash
# @trace order:829-dkuc
#
# THE SWEEP'S OWN RITUAL DETECTOR. Packet 829-dkuc names four rules whose
# entire purpose is to stop the de-slop sweep becoming the thing it hunts, and
# says of them: "these are not optional, each is computable from the stamp
# record", and "the step is subject to its own ritual detector, no exemption".
# This script is that detector. It reads plan/deslop-sweeps.d/*.md — the same
# records scripts/check-deslop-due.sh writes — and computes:
#
#   KILL RULE        two consecutive sweeps that EXAMINED rows and confirmed
#                    nothing => red:two-sweeps-zero-confirmed. Sweeps that
#                    examined nothing are skipped, not counted as zero: the
#                    2026-08-20 sizing note is explicit that the rule must
#                    "count only sweeps that examined new rows", or a sweep
#                    that correctly found a quiet tree retires the reconciler
#                    for doing nothing wrong.
#   REFUTATION BAND  over the 4 trailing sweeps, 0% refuted => the finder is
#                    rubber-stamping; 100% => it is producing nothing real.
#   NET-NEGATIVE     a sweep's own diff must delete more than it adds.
#   FILING CAP       at most 5 packets filed per sweep, and it must retract at
#                    least as many rows as it files.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO. It does not run a sweep, delete
# anything, retract anything, or write to the ledger. The sweep itself is the
# half of 829-dkuc that its own next_action reserves for an operator-paired
# session, and lenovinha declined it three times on that ground (2026-08-26,
# "PRIORITY IS NOT PERMISSION"). Governance can be built without the deletion;
# the deletion should not be run without the governance.
#
# ── THE PROPERTY THIS SCRIPT EXISTS TO PRESERVE ──────────────────────────────
#
# "CANNOT TELL" IS NOT "HEALTHY", AND THEY GET DIFFERENT EXIT CODES. Every rule
# above needs history the ledger may not have: the kill rule needs two scoring
# sweeps, the band needs four carrying `findings=`, net-negative needs
# `net_lines=`, the cap needs `filed=`. A detector that returned ok: while
# silently scoring nothing would be a green earned by absent data — the exact
# shape 1106-k2df was filed for, where a value true about the artefact (no rule
# fired) was read as the property it names (the sweep is healthy). So an
# unscoreable rule is named as unscoreable, out loud, and the run exits 2.
#
# On the ledger as it stands TODAY that is not hypothetical: there is exactly
# one record, it is the hand-seeded pre-clock one, and it carries neither
# `findings=` nor `filed=` nor `net_lines=`. NONE of the four rules can score
# it. That is this detector's first real finding about the packet that owns it.
#
# ONE RULE HALF IS UNREACHABLE, AND IT IS NAMED RATHER THAN QUIETLY KEPT.
# `red:refutation-rate-degenerate:100` cannot fire in production: four sweeps
# that confirmed nothing while examining rows trip the KILL RULE at sweep two,
# and check-deslop-due.sh refuses to write a record without --examined, so the
# examined=0 escape does not occur either. The 100% end is therefore dead
# against the kill rule. Left in place, pinned by a self-test arm that asserts
# the PRECEDENCE, and reported upward: dropping it or giving it a reachable
# meaning is an operator call, alongside the still-open D4 (class token names).
#
# Usage:
#   scripts/check-deslop-sweep-health.sh            -> one verdict line
#   scripts/check-deslop-sweep-health.sh --self-test
#   TILLANDSIAS_DESLOP_LEDGER_DIR=<dir>  fixture seam (same var as the writer)
#
# Exit: 0 every applicable rule evaluated and passed
#       1 a rule fired (red:)
#       2 nothing could be scored, or usage/infra failure
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "fail:deslop-health:no-repo-root"; exit 2; }
LEDGER_DIR="${TILLANDSIAS_DESLOP_LEDGER_DIR:-$ROOT/plan/deslop-sweeps.d}"

BAND_WINDOW=4
FILING_CAP=5

# Emits one `REC <ts> <order> <examined> <confirmed> <findings> <retracted> <filed> <net>`
# per well-formed record, oldest first, with `-` for any absent field. Fields are
# space-split and anchored exactly as check-deslop-due.sh reads them (803-bqte:
# no GNU-only regex atom), so a record may grow new fields in any order.
_scan() {
    local f found=0
    for f in "$LEDGER_DIR"/*.md; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in README.md) continue ;; esac
        found=1
        awk '
            /^## / {
                ts = ""
                if ($0 ~ /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z [^ ]+$/) ts = $2
                next
            }
            /^DESLOP-SWEEP:/ {
                ord="-"; ex="-"; cf="-"; fi="-"; re="-"; fl="-"; nl="-"
                for (i = 2; i <= NF; i++) {
                    if ($i ~ /^order=[0-9]+$/)          ord = substr($i, 7)
                    else if ($i ~ /^examined=[0-9]+$/)  ex  = substr($i, 10)
                    else if ($i ~ /^confirmed=[0-9]+$/) cf  = substr($i, 11)
                    else if ($i ~ /^findings=[0-9]+$/)  fi  = substr($i, 10)
                    else if ($i ~ /^retracted=[0-9]+$/) re  = substr($i, 11)
                    else if ($i ~ /^filed=[0-9]+$/)     fl  = substr($i, 7)
                    else if ($i ~ /^net_lines=[-+]?[0-9]+$/) nl = substr($i, 11) + 0
                }
                if (ts == "" || ord == "-") next
                printf "REC %s %s %s %s %s %s %s %s\n", ts, ord, ex, cf, fi, re, fl, nl
            }
        ' "$f"
    done
    [ "$found" -eq 1 ] || return 1
    return 0
}

_verdict() {
    local recs
    recs="$(_scan | sort -k3,3n)" || {
        echo "fail:deslop-health:no-ledger-dir:$LEDGER_DIR"; return 2; }
    if [ -z "$recs" ]; then
        echo "unknown:deslop-health:no-records — the ledger holds no well-formed DESLOP-SWEEP line, so no rule can score. This is NOT a pass."
        return 2
    fi

    local total; total="$(printf '%s\n' "$recs" | grep -c '^REC ')"

    # ── KILL RULE ─────────────────────────────────────────────────────────────
    # Only sweeps with examined>0 score. Two consecutive scoring sweeps at
    # confirmed=0 retire the packet.
    local scoring streak=0 worst="" prev=""
    scoring="$(printf '%s\n' "$recs" | awk '$4 != "-" && $4 > 0 && $5 != "-" { print $3" "$5" "$2 }')"
    local n_scoring=0
    if [ -n "$scoring" ]; then n_scoring="$(printf '%s\n' "$scoring" | grep -c .)"; fi
    while read -r ord cf ts; do
        [ -n "${ord:-}" ] || continue
        if [ "$cf" -eq 0 ]; then
            streak=$((streak + 1))
            [ "$streak" -ge 2 ] && worst="$prev,$ts"
        else
            streak=0
        fi
        prev="$ts"
    done <<EOF
$scoring
EOF
    if [ -n "$worst" ]; then
        echo "red:two-sweeps-zero-confirmed:$worst — two consecutive sweeps examined rows and confirmed nothing; 829-dkuc's kill rule sets that packet to obsoleted with reason deslop:ritual:self, no exemption"
        return 1
    fi

    # ── NET-NEGATIVE DIFF ─────────────────────────────────────────────────────
    local bad_net
    bad_net="$(printf '%s\n' "$recs" | awk '$9 != "-" && $9 >= 0 { print $3"="$9 }' | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$bad_net" ]; then
        echo "red:net-positive-diff:$bad_net — a sweep must delete more than it adds (excluding litmus and scripts/check-*)"
        return 1
    fi

    # ── FILING CAP ────────────────────────────────────────────────────────────
    local over_cap
    over_cap="$(printf '%s\n' "$recs" | awk -v cap="$FILING_CAP" '$8 != "-" && $8 > cap { print $3"=filed"$8 }' | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$over_cap" ]; then
        echo "red:filing-cap-exceeded:$over_cap — at most $FILING_CAP packets per sweep"
        return 1
    fi
    local under_retract
    under_retract="$(printf '%s\n' "$recs" | awk '$8 != "-" && $7 != "-" && $8 > $7 { print $3"=filed"$8"/retracted"$7 }' | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$under_retract" ]; then
        echo "red:filed-exceeds-retracted:$under_retract — a sweep must retract at least as many rows as it files, or it is a net filer wearing a reducer's name"
        return 1
    fi

    # ── REFUTATION BAND ───────────────────────────────────────────────────────
    local band band_n=0 sum_f=0 sum_c=0
    band="$(printf '%s\n' "$recs" | awk '$6 != "-" && $5 != "-" { print $6" "$5 }' | tail -n "$BAND_WINDOW")"
    if [ -n "$band" ]; then
        band_n="$(printf '%s\n' "$band" | grep -c .)"
        sum_f="$(printf '%s\n' "$band" | awk '{s+=$1} END {print s+0}')"
        sum_c="$(printf '%s\n' "$band" | awk '{s+=$2} END {print s+0}')"
    fi
    local rate="-"
    if [ "$band_n" -ge "$BAND_WINDOW" ] && [ "$sum_f" -gt 0 ]; then
        rate=$(( (sum_f - sum_c) * 100 / sum_f ))
        if [ "$rate" -eq 0 ]; then
            echo "red:refutation-rate-degenerate:0 — over $BAND_WINDOW trailing sweeps every finding was confirmed; a finder that is never wrong is not being falsified"
            return 1
        fi
        if [ "$rate" -eq 100 ]; then
            echo "red:refutation-rate-degenerate:100 — over $BAND_WINDOW trailing sweeps nothing was confirmed; the finder is producing nothing real"
            return 1
        fi
    fi

    # ── WHAT COULD NOT BE SCORED ──────────────────────────────────────────────
    # Named individually. A rule that had no data must not hide inside a pass.
    local un=""
    [ "$n_scoring" -ge 2 ] || un="$un,kill-rule(needs-2-scoring-sweeps-have-$n_scoring)"
    [ "$band_n" -ge "$BAND_WINDOW" ] || un="$un,refutation-band(needs-$BAND_WINDOW-with-findings-have-$band_n)"
    printf '%s\n' "$recs" | awk '$9 != "-"' | grep -q . || un="$un,net-negative(no-record-carries-net_lines)"
    printf '%s\n' "$recs" | awk '$8 != "-"' | grep -q . || un="$un,filing-cap(no-record-carries-filed)"

    if [ -n "$un" ]; then
        echo "unknown:deslop-health:sweeps=$total unscoreable:${un#,} — no rule fired, but these could not be evaluated; that is not a pass"
        return 2
    fi
    echo "ok:deslop-health:sweeps=$total scoring=$n_scoring refutation=${rate}% — every applicable rule evaluated and passed"
    return 0
}

# ── Self-test ────────────────────────────────────────────────────────────────
_self_test() {
    local fail=0 pass=0 W
    W="$(mktemp -d "${TMPDIR:-/tmp}/deslop-health.XXXXXX")" || return 2
    trap 'rm -rf "$W"' RETURN
    ok()  { echo "ok:   $1"; pass=$((pass+1)); }
    bad() { echo "FAIL: $1" >&2; fail=1; }

    _mk() { # _mk <file> <records...>  each record is a bare field list
        local f="$W/$1"; shift
        : > "$f"
        local i=0
        for rec in "$@"; do
            i=$((i+1))
            printf '## 2026-09-0%dT00:00:00Z fixture\n' "$i" >> "$f"
            printf 'DESLOP-SWEEP: %s\n' "$rec" >> "$f"
        done
    }
    _run() { TILLANDSIAS_DESLOP_LEDGER_DIR="$W" bash "$0" 2>&1; }

    # 1. EMPTY LEDGER IS NOT A PASS.
    _mk a.md
    out="$(_run)"; rc=$?
    case "$out" in
        unknown:deslop-health:no-records*) [ "$rc" -eq 2 ] \
            && ok "an empty ledger is unknown+exit2, not ok" \
            || bad "empty ledger gave the right verdict but exit $rc (must be 2)" ;;
        *) bad "empty ledger returned: $out" ;;
    esac

    # 2. THE KILL RULE FIRES on two consecutive scoring sweeps at zero.
    _mk a.md "order=100 examined=10 confirmed=0" "order=200 examined=10 confirmed=0"
    out="$(_run)"; rc=$?
    case "$out" in
        red:two-sweeps-zero-confirmed:*) [ "$rc" -eq 1 ] && ok "kill rule fires and exits 1" || bad "kill rule verdict but exit $rc" ;;
        *) bad "kill rule did not fire: $out" ;;
    esac

    # 3. CONTROL — A SWEEP THAT EXAMINED NOTHING MUST NOT COUNT AS A ZERO.
    # This is the arm the 2026-08-20 sizing note demands, and without it a
    # quiet fortnight retires the packet for behaving correctly.
    _mk a.md "order=100 examined=0 confirmed=0" "order=200 examined=0 confirmed=0"
    out="$(_run)"
    case "$out" in
        red:two-sweeps-zero-confirmed:*) bad "a sweep that examined NOTHING was counted as a zero-confirmed sweep — this retires the packet for a quiet tree" ;;
        *) ok "examined=0 sweeps are skipped by the kill rule, not counted" ;;
    esac

    # 4. CONTROL — a confirming sweep between two zeros breaks the streak.
    _mk a.md "order=100 examined=9 confirmed=0" "order=200 examined=9 confirmed=3" "order=300 examined=9 confirmed=0"
    out="$(_run)"
    case "$out" in
        red:two-sweeps-zero-confirmed:*) bad "non-consecutive zeros fired the kill rule: $out" ;;
        *) ok "a confirming sweep between two zeros breaks the streak" ;;
    esac

    # 5. NET-POSITIVE DIFF fires.
    _mk a.md "order=100 examined=9 confirmed=2 net_lines=+40"
    case "$(_run)" in
        red:net-positive-diff:*) ok "a sweep that added more than it deleted is red" ;;
        *) bad "net-positive diff not caught: $(_run)" ;;
    esac
    # 5b. CONTROL — a negative diff is not red.
    _mk a.md "order=100 examined=9 confirmed=2 net_lines=-40"
    case "$(_run)" in
        red:net-positive-diff:*) bad "a NEGATIVE net diff was flagged — the sign is inverted" ;;
        *) ok "a net-negative sweep passes that rule" ;;
    esac

    # 6. FILING CAP and the retract>=file rule.
    _mk a.md "order=100 examined=9 confirmed=2 filed=6 retracted=9"
    case "$(_run)" in
        red:filing-cap-exceeded:*) ok "filing more than $FILING_CAP packets is red" ;;
        *) bad "filing cap not caught: $(_run)" ;;
    esac
    _mk a.md "order=100 examined=9 confirmed=2 filed=3 retracted=1"
    case "$(_run)" in
        red:filed-exceeds-retracted:*) ok "filing more than it retracts is red" ;;
        *) bad "net-filer not caught: $(_run)" ;;
    esac

    # 7. REFUTATION BAND, both ends.
    _mk a.md "order=1 examined=9 confirmed=4 findings=4" "order=2 examined=9 confirmed=4 findings=4" \
             "order=3 examined=9 confirmed=4 findings=4" "order=4 examined=9 confirmed=4 findings=4"
    case "$(_run)" in
        red:refutation-rate-degenerate:0*) ok "0% refutation over the band is red" ;;
        *) bad "degenerate-0 not caught: $(_run)" ;;
    esac
    # 7b. THE KILL RULE SUBSUMES THE 100% END OF THE BAND, and this arm pins
    # that rather than accepting either verdict. Four sweeps that examined rows
    # and confirmed nothing are ALSO two consecutive zero-confirmed sweeps, so
    # the kill rule fires first and degenerate-100 never speaks. Given the
    # writer REFUSES a record without --examined, and a sweep with examined=0
    # has nothing to have findings about, `red:refutation-rate-degenerate:100`
    # is unreachable in production. That is a finding ABOUT 829-dkuc's own rule
    # set, surfaced by its own detector, and it is recorded rather than tidied:
    # the honest options are to drop the 100% end or to give it a reachable
    # meaning, and that is an operator call alongside the still-open D4.
    _mk a.md "order=1 examined=9 confirmed=0 findings=4" "order=2 examined=9 confirmed=0 findings=4" \
             "order=3 examined=9 confirmed=0 findings=4" "order=4 examined=9 confirmed=0 findings=4"
    out="$(_run)"
    case "$out" in
        red:two-sweeps-zero-confirmed:*) ok "an all-refuted band reds via the kill rule, which preempts degenerate-100" ;;
        red:refutation-rate-degenerate:100*) bad "degenerate-100 fired before the kill rule — precedence changed; the header note about unreachability is now stale" ;;
        *) bad "all-refuted band not caught at all: $out" ;;
    esac

    # 8. THE HONEST-UNKNOWN ARM, and it is the one this script exists for.
    # A single record with no findings=/filed=/net_lines= scores NOTHING, and
    # must say so rather than return ok.
    _mk a.md "order=834 examined=410 confirmed=51 retracted=51"
    out="$(_run)"; rc=$?
    case "$out" in
        ok:*) bad "a lone unscoreable record returned ok: — this is the green-earned-by-absent-data shape: $out" ;;
        unknown:deslop-health:sweeps=1*)
            [ "$rc" -eq 2 ] || bad "unknown verdict but exit $rc (must be 2)"
            case "$out" in
                *kill-rule*)        ok "unknown names the kill rule as unscoreable" ;;
                *) bad "unknown did not name the kill rule: $out" ;;
            esac
            case "$out" in
                *refutation-band*)  ok "unknown names the refutation band as unscoreable" ;;
                *) bad "unknown did not name the band: $out" ;;
            esac
            case "$out" in
                *net-negative*)     ok "unknown names net-negative as unscoreable" ;;
                *) bad "unknown did not name net-negative: $out" ;;
            esac
            case "$out" in
                *filing-cap*)       ok "unknown names the filing cap as unscoreable" ;;
                *) bad "unknown did not name the filing cap: $out" ;;
            esac ;;
        *) bad "lone seeded record returned: $out" ;;
    esac

    # 9. A FULLY-SCORED HEALTHY LEDGER RETURNS ok — the positive control that
    # stops "refuse always" passing as a detector.
    _mk a.md "order=1 examined=9 confirmed=3 findings=4 filed=1 retracted=2 net_lines=-10" \
             "order=2 examined=9 confirmed=3 findings=4 filed=1 retracted=2 net_lines=-10" \
             "order=3 examined=9 confirmed=3 findings=4 filed=1 retracted=2 net_lines=-10" \
             "order=4 examined=9 confirmed=3 findings=4 filed=1 retracted=2 net_lines=-10"
    out="$(_run)"; rc=$?
    case "$out" in
        ok:deslop-health:*) [ "$rc" -eq 0 ] && ok "a fully-scored healthy ledger is ok+exit0" || bad "ok verdict but exit $rc" ;;
        *) bad "healthy ledger did not pass: $out" ;;
    esac

    echo "deslop-sweep-health: $pass passed$([ "$fail" -eq 0 ] || echo ", FAILURES")"
    return "$fail"
}

case "${1:-}" in
    --self-test) _self_test; exit $? ;;
    "") _verdict; exit $? ;;
    *) echo "fail:deslop-health:usage: check-deslop-sweep-health.sh [--self-test]"; exit 2 ;;
esac

#!/usr/bin/env bash
# @trace order:1395-ue3i
#
# check-centicolon-ratchet.sh — print the CentiColon R line on every --check.
# ADVISORY (operator ruling 2026-09-26, recorded on 1395-ue3i): it WARNS and
# never refuses; it always exits 0.
#
#   centicolon: R=<n> satisfied=<n> denominator=<n> added=<n> retired=<n> lost=<n> histogram=declared:<a>,traced:<b>,positively_tested:<c> regime=<r> (advisory)
#
# THE RATCHET SEMANTICS, centipawn-style (operator ruling, 813a552e2), against
# the previous run on this host (snapshot <out>/last.txt, untracked):
#   added    obligation ids that are new. Adding a spec or requirement ADDS to
#            the target and changes no existing obligation: scope growth, never
#            regression.
#   retired  ids that vanished WITH a tombstone trail — their spec left the
#            counted set and the registry carries a `tombstone:` for it or an
#            openspec/changes record names the spec; or the req-id itself is
#            named in openspec/changes. Removed by design, not a regression.
#   lost     the regression, and the only thing that WARNS:
#              vanished — an id disappeared with NO such record
#              down     — an id still present whose state moved down
#                         (positively_tested > traced > declared)
#            warn:centicolon-ratchet:lost=<n>:vanished=<v>,down=<d>:<first id>
# MONOTONIC means the satisfied count and no lost obligation, never the raw
# ratio. regime: baseline (no snapshot) | monotone | any of lost, scope-added,
# retired joined with "+", lost first.
#
# A pipeline that cannot run prints `centicolon: blocked:<why> (advisory)` —
# never an R of 0. The grader's static refusals pass through as warn: lines.
#
# --no-snapshot: report without advancing the snapshot (cycle-metrics.sh uses
# this, so a reporting pass never swallows the next --check's warning).
set -uo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TILLANDSIAS_REPO_ROOT:-$(cd "$SCRIPTS/.." && pwd)}"
OUT="$ROOT/${TILLANDSIAS_CENTICOLON_DIR:-target/centicolon}"
snapshot=1
[ "${1:-}" = "--no-snapshot" ] && snapshot=0

# The plan binary answers the JSON reads below (`json get`, 1375-rn9b — no jq).
# Resolved from this checkout and made absolute, then handed to the wrapper.
. "$SCRIPTS/plan-binary-probe.sh"
if ! PLAN="$(cd "$SCRIPTS/.." && resolve_plan_binary)"; then
    echo "centicolon: blocked:no-runnable-plan-binary (advisory)"; exit 0
fi
case "$PLAN" in /*) ;; *) PLAN="$(cd "$SCRIPTS/.." && cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")" ;; esac
export TILLANDSIAS_PLAN_BIN="$PLAN"

res="$(bash "$SCRIPTS/centicolon-grade.sh" 2>&1)"
grep '^warn:' <<<"$res" || true
verdict="$(grep -m1 -E '^(ok|blocked):centicolon-grade:' <<<"$res")"
if [ "${verdict%%:*}" != ok ] || [ ! -s "$OUT/grade.json" ]; then
    echo "centicolon: blocked:${verdict#blocked:centicolon-grade:} (advisory)"
    exit 0
fi

kv() { sed -n "s/.* $1=\([0-9]*\).*/\1/p" <<<" ${verdict#ok:centicolon-grade:}"; }
R="$(kv R)"; sat="$(kv satisfied)"; den="$(kv denominator)"
dec="$(kv declared)"; tra="$(kv traced)"; pt="$(kv positively_tested)"

# One line per obligation: "<id> <state> <spec> <req-id>", sorted (the observed
# grader emits them ready-made as `snapshot`, so no string building here).
now="$("$PLAN" json get -r '.snapshot[]' "$OUT/grade.json" 2>/dev/null | tr -d '\r' | LC_ALL=C sort)"
counted_specs="$("$PLAN" json get -r '.specs_counted | keys[]' "$OUT/obligations.json" 2>/dev/null | tr -d '\r')"

# has_trail <spec> <req-id> — a tombstone trail for a vanished obligation.
has_trail() {
    local spec="$1" req="$2"
    if [ -d "$ROOT/openspec/changes" ] && grep -rqF -- "$req" "$ROOT/openspec/changes" 2>/dev/null; then return 0; fi
    grep -qxF -- "$spec" <<<"$counted_specs" && return 1     # spec still counted: only a req-level record retires it
    awk -v s="$spec" '$0 ~ "^- spec_id: "s"$" {f=1; next} f && /^- spec_id:/ {exit} f && /^  tombstone:/ {found=1; exit} END {exit !found}' \
        "$ROOT/openspec/litmus-bindings.yaml" 2>/dev/null && return 0
    [ -d "$ROOT/openspec/changes" ] && grep -rqF -- "$spec" "$ROOT/openspec/changes" 2>/dev/null && return 0
    return 1
}

added=0; retired=0; vanished=0; down=0; first=""; regime=""
if [ -s "$OUT/last.txt" ]; then
    # ONE pass joins the snapshot with this run: prints "added <n>",
    # "down <n> <first-id>", and one "gone <id> <spec> <req>" per vanished id.
    joined="$(awk '
        function rank(s) { return s == "positively_tested" ? 2 : (s == "traced" ? 1 : 0) }
        NR == FNR { prev[$1] = $2; pspec[$1] = $3; preq[$1] = $4; next }
        { cur[$1] = $2; if (!($1 in prev)) added++ }
        END {
            for (id in prev) {
                if (!(id in cur)) print "gone", id, pspec[id], preq[id]
                else if (rank(cur[id]) < rank(prev[id])) { down++; if (fd == "" || id < fd) fd = id }
            }
            print "added", added + 0
            print "down", down + 0, fd
        }' "$OUT/last.txt" <(printf '%s\n' "$now"))"
    added="$(awk '$1 == "added" {print $2}' <<<"$joined")"
    down="$(awk '$1 == "down" {print $2}' <<<"$joined")"
    first="$(awk '$1 == "down" {print $3}' <<<"$joined")"
    while read -r _ id spec req; do
        [ -n "$id" ] || continue
        if has_trail "$spec" "$req"; then retired=$((retired + 1))
        else vanished=$((vanished + 1)); { [ -z "$first" ] || [[ "$id" < "$first" ]]; } && first="$id"; fi
    done < <(grep '^gone ' <<<"$joined" | LC_ALL=C sort)
    lost=$((vanished + down))
    if [ "$lost" -gt 0 ]; then
        regime="lost"
        echo "warn:centicolon-ratchet:lost=$lost:vanished=$vanished,down=$down:$first"
    fi
    [ "${added:-0}" -gt 0 ] && regime="${regime:+$regime+}scope-added"
    [ "$retired" -gt 0 ] && regime="${regime:+$regime+}retired"
    [ -n "$regime" ] || regime="monotone"
else
    lost=0; regime="baseline"
fi
[ "$snapshot" -eq 1 ] && printf '%s\n' "$now" >"$OUT/last.txt"

echo "centicolon: R=$R satisfied=$sat denominator=$den added=$added retired=$retired lost=$lost histogram=declared:$dec,traced:$tra,positively_tested:$pt regime=$regime (advisory)"
exit 0

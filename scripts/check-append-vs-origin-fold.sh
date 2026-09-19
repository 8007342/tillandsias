#!/usr/bin/env bash
# @trace order:1261-bn7v, spec:ci-release
#
# check-append-vs-origin-fold.sh — refuse a push whose long-form field value
# DROPS A LINE ORIGIN'S FOLD CARRIES.
#
# THE DEFECT (1261-bn7v). `set-field --append`'s drops-lines guard (1151-td46)
# compares against the fold THE WRITING HOST HOLDS. A host that has not fetched
# a peer's newer append cannot see it, so the append passes the guard and —
# because LWW is per FIELD, not per line — the peer's lines are deleted with no
# conflict and no marker. Reproduced 2026-09-18 with two clones three seconds
# apart: both fragments reached the remote, the later value carried BASE+L2 with
# no L1, git merged clean, and set-field printed ok: twice.
#
# WHY IT COMPARES FOLDS AND NOT FRAGMENT TEXT. The obvious implementation parses
# the outgoing fragment's `value:` block scalar and diffs that. It is wrong:
# what lands is not the fragment, it is the FOLD of every fragment, and a push
# may carry several touching one field. So this asks the ledger the same
# question twice — once in the worktree (the fold this push produces) and once
# in an extraction of origin (the fold that exists) — and compares the answers.
# Block-scalar parsing is avoided entirely; only single-line keys are read.
#
# Verdicts:
#   ok:append-vs-origin:checked:<n>
#   refused:append-drops-lines-vs-origin:<packet>:<field>
#   skip:append-vs-origin:<reason>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0
FRAG_DIR="${TILLANDSIAS_FRAG_DIR:-plan/index.d}"
TRUNK_REF="${TILLANDSIAS_ORIGIN_REF:-refs/remotes/origin/linux-next}"

# shellcheck source=scripts/plan-binary-probe.sh
. scripts/plan-binary-probe.sh 2>/dev/null || true
if ! command -v resolve_plan_binary >/dev/null 2>&1; then
    echo "skip:append-vs-origin:no-probe-lib"; exit 0
fi
PLAN="$(resolve_plan_binary)" || { echo "skip:append-vs-origin:no-plan-binary"; exit 0; }
# ABSOLUTISE WITHOUT CLOBBERING AN ALREADY-ABSOLUTE PATH. resolve_plan_binary
# returns "./target/release/..." normally but passes a TILLANDSIAS_PLAN_BIN
# override through verbatim, which fixtures use — and blindly prefixing $ROOT
# onto that produced "$ROOT/abs/path", a file that does not exist, so this
# script reported plan-binary-lacks-field-get against a binary that has it.
case "$PLAN" in
    /*) PLAN_ABS="$PLAN" ;;
    *)  PLAN_ABS="$ROOT/${PLAN#./}" ;;
esac

# The subcommand is what makes this checkable at all; a binary without it is a
# skip and not a pass. CAPTURE THEN MATCH (795-imz3) — `| grep -q` under the
# `set -o pipefail` above reports failure ON A MATCH.
_probe="$("$PLAN_ABS" field-get 9999-nosuch next_action 2>&1)"
case "$_probe" in
    *unset:field-get*|*error:*) ;;
    *) echo "skip:append-vs-origin:plan-binary-lacks-field-get"; exit 0 ;;
esac

git rev-parse --verify --quiet "$TRUNK_REF" >/dev/null 2>&1 || {
    echo "skip:append-vs-origin:no-origin-ref"; exit 0; }

# LONG-FORM FIELDS ONLY. A scalar field replaced wholesale is the LWW channel
# working as designed; only prose accumulates lines that another host's warning
# can live in. Same list 1151-td46 guards.
_is_long_form() {
    case "$1" in
        next_action|context|notes|title|deliverable|verifiable_closure|unscoreable|provenance|progress_summary) return 0 ;;
        *) return 1 ;;
    esac
}

# Which (packet_id, field) pairs does this push touch? Scoped to the LWW
# `status:` block, reset per FILE — the 864-hv2n lesson: awk state is global,
# and a fragment ending inside its block otherwise carries pid into the next
# file and misattributes it.
pairs="$(awk '
    FNR == 1 { in_s = 0; pid = ""; fld = "" }
    /^status:[[:space:]]*$/   { in_s = 1; pid = ""; fld = ""; next }
    /^[a-z_]+:[[:space:]]*$/  { in_s = 0; pid = ""; fld = "" }
    in_s && /^  - packet_id:/ { pid = $3; fld = ""; next }
    in_s && /^    field:/     { fld = $2; if (pid != "") print pid "\t" fld }
' "$FRAG_DIR"/*.yaml 2>/dev/null | sort -u)"

[ -n "$pairs" ] || { echo "ok:append-vs-origin:checked:0"; exit 0; }

TMP="$(mktemp -d)" || { echo "skip:append-vs-origin:no-tmpdir"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
git archive "$TRUNK_REF" plan/ 2>/dev/null | tar -x -C "$TMP" 2>/dev/null || {
    echo "skip:append-vs-origin:cannot-extract-origin"; exit 0; }

checked=0; refused=0
while IFS=$'\t' read -r pid field; do
    [ -n "$pid" ] && [ -n "$field" ] || continue
    _is_long_form "$field" || continue

    # Origin's fold. Exit 3 means UNSET on origin — nothing to drop, which is
    # not the same as empty and must not be treated as a mismatch (1260-2qgi).
    origin_val="$(cd "$TMP" && "$PLAN_ABS" field-get "$pid" "$field" 2>/dev/null)"
    orc=$?
    [ "$orc" -eq 0 ] || continue

    # The fold THIS PUSH produces, asked of the worktree.
    local_val="$("$PLAN_ABS" field-get "$pid" "$field" 2>/dev/null)" || continue

    checked=$((checked + 1))
    dropped=""
    while IFS= read -r line; do
        [ -n "${line// /}" ] || continue
        case $'\n'"$local_val"$'\n' in
            *$'\n'"$line"$'\n'*) ;;
            *) dropped="${dropped}${line}"$'\n' ;;
        esac
    done <<EOF
$origin_val
EOF

    if [ -n "$dropped" ]; then
        refused=$((refused + 1))
        echo "refused:append-drops-lines-vs-origin:${pid}:${field}"
        echo "  This push's fold of ${pid}.${field} DROPS $(printf '%s' "$dropped" | grep -c .) line(s) that origin carries." >&2
        printf '%s' "$dropped" | head -10 | sed 's/^/    would drop: /' >&2
        # NAME THE FRAGMENT ON ORIGIN, so the remedy is mechanical and not a
        # guess — this row's own next_action asks for exactly this.
        owner="$(grep -l -- "$(printf '%s' "$dropped" | head -1)" "$TMP/$FRAG_DIR"/*.yaml 2>/dev/null | head -1)"
        [ -n "$owner" ] && echo "  origin carries it in: ${owner#$TMP/}" >&2
        echo "  REMEDY: git fetch origin, re-read the field, and rebuild your value on top of it." >&2
        echo "  Your --append was written against a fold that never had those lines, so the" >&2
        echo "  1151-td46 drop guard had nothing to compare them with (1261-bn7v)." >&2
    fi
done <<EOF
$pairs
EOF

if [ "$refused" -gt 0 ]; then
    exit 1
fi
echo "ok:append-vs-origin:checked:${checked}"

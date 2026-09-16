#!/usr/bin/env bash
# @trace spec:versioning, spec:ci-release
#
# check-must-ship-rows.sh — name the rows marked REQUIRED FOR THE NEXT CUT whose
# fix is not in the tree being cut.
#
# Order 1218-25z3. ADVISORY: exits 0 on every finding. See THE STRENGTH
# DECISION below — that it reports rather than blocks is a recorded decision,
# not an implementation accident.
#
# ── WHY IT EXISTS ───────────────────────────────────────────────────────────
#
# The operator, 2026-09-16, after hitting 1215-xazj live on a freshly-promoted
# stable: "take note of anything that needs to get done, and make sure it
# happens by the next release whenever that happens." There was nowhere to put
# that instruction. release-preflight.sh carries four gates — VERSION
# monotonicity, retired CLI flags, plan-ledger integrity, the Actions budget —
# and none reads the ledger for a row required in the next cut.
#
# MEASURED COST: 1211-34v6 removed a refusal that advertises a remedy its own
# resolver cannot read. It landed on trunk and was NOT in the cut that followed,
# so the promoted stable still sends operators in a circle. Nothing was done
# wrong; NO GATE ASKED. A release cut is exactly the moment the person cutting
# has the least context about what six other hosts found that week.
#
# ── HOW A ROW IS MARKED ─────────────────────────────────────────────────────
#
#   tillandsias-plan set-field <order> must_ship next --host <h> --reason "…"
#
# THREE MECHANISMS WERE MEASURED AND TWO ARE BLOCKED; the field is not a first
# idea, it is the only one that works on an EXISTING row:
#   * capability_tags IS projected and IS exactly filterable (`--tag`, where a
#     substring returns []), but set-field REFUSES list-valued fields
#     (1184-tj2q): writing one reads the existing list as unset and replaces it
#     with a string, after which the row matches NO tag query at all. A row can
#     therefore only be tagged in its own declaration, and declarations are
#     immutable.
#   * an EVENT of a distinctive type is appendable by any host, but `plan-events`
#     prints `<type>\t<ts>` per packet and there is no bulk reader by type, so
#     finding marked rows would mean invoking it once per packet.
#   * a novel top-level scalar validates under `check --strict-fragments` and
#     set-field CAN write it — but `query --json` is an explicit key ALLOWLIST,
#     so until this order it was writable and unreadable. `must_ship` is now in
#     that allowlist, for the reason 627-cx24 records beside it: a projection
#     that silently drops a field a consumer reads fails in a direction nothing
#     observes.
#
# WHICH MAKES A STALE BINARY DANGEROUS HERE, and it is probed rather than
# assumed. A tillandsias-plan predating this order answers the same query with
# `must_ship` silently absent, and a consumer reading nothing concludes "no rows
# are marked" — the answer that looks like success. Before trusting a zero, this
# script builds a throwaway index containing a marked row and checks that the
# field survives the projection. That is falsifying the instrument on the exact
# question, not reading a version number.
#
# ── HOW "IS THE FIX IN THE CUT" IS DECIDED ──────────────────────────────────
#
# A commit IS a row's fix when its SUBJECT carries the order in the project's
# `type(order): …` convention. Anchoring on the subject is load-bearing, not
# tidiness: `git log --grep=1211-34v6 origin/linux-next` returns FIVE commits,
# three of which merely MENTION the order in their body — including this
# author's own correction commits. Subject-anchored returns TWO, the fix and
# its closure. Counting mentions would report a row as shipped because someone
# discussed it.
#
# THE LIMIT, stated so silence is not read as coverage: this trusts the commit
# convention. A fix landed with a subject that does not name its order is
# invisible here and will be reported outstanding — a FALSE ALARM, which is the
# safe direction. `evidence_refs` was considered and rejected as the source: it
# lives in event PROSE, not in a structured field, so parsing a sha out of it
# would be a guess.
#
# ── THE STRENGTH DECISION: REPORTS, DOES NOT BLOCK ──────────────────────────
#
# Recorded here and on the row as a decision with its reason (1218-25z3
# criterion 4 requires exactly that, rather than letting the implementer settle
# it silently).
#
#   * A blocking gate at cut time is bypassed, not obeyed. 748-tkjx already
#     settled the general form: a gate expensive or inconvenient enough at the
#     wrong moment gets routed around with --no-verify, and then protects
#     nothing. A cut under a freeze window is that moment.
#   * The cutter may legitimately ship without a marked row — the operator can
#     decide a fix waits. A gate that cannot express "yes, I know" converts a
#     judgement into an obstacle.
#   * The defect was never that someone overrode a warning; it was that NOBODY
#     WAS TOLD. Reporting closes the measured gap completely.
#   * The tray-parity completeness check is the local precedent for a
#     release-scoped advisory the operator can override.
#
# REVERSIBLE, and deliberately the cheaper direction first: if a marked row is
# ever missed AFTER this reports it, that is new evidence and the strength
# should be revisited. Advisory-to-blocking is a one-line change; the reverse
# costs a release.
#
# ── VERDICT GRAMMAR (closed) ────────────────────────────────────────────────
#   ^(ok:must-ship:0 outstanding of [0-9]+ marked
#    |advisory:must-ship:[0-9]+ outstanding of [0-9]+ marked
#    |skipped:must-ship:(no-plan-binary|stale-plan-binary|no-cut-ref|no-jq)
#    |fail:must-ship:(unreadable-ledger|unknown-argument|missing-value))$
#
# `skipped:` is its own word: a pass that never ran must never report `ok`
# (785-sqe6, 787-f7dh). Every verdict names its denominator.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

MARKER="next"
CUT_REF="HEAD"
# REFUSE AN UNKNOWN ARGUMENT RATHER THAN DISCARDING IT (found by macuahuitl
# hitting it, not by reading the code). This loop used to end `*) shift ;;`, so
# `check-must-ship-rows.sh v56.9.13.1` and `--against v56.9.13.1` both DROPPED
# the ref and reported `ok:must-ship:0 outstanding of 2 marked` — a confident
# clean verdict about HEAD, a tree nobody asked about. The only tell was the ref
# name inside the per-row detail, which a reader scanning for the verdict does
# not read.
#
# THAT IS THIS SCRIPT'S OWN SUBJECT TURNED ON ITSELF: a well-formed answer to a
# question that was never asked. It matters more here than in most scripts,
# because the caller is a release cutter typing a flag from memory at the moment
# they have the least context — exactly the reader this row exists to protect.
while [ $# -gt 0 ]; do
    case "$1" in
        # `shift 2` with only one argument left FAILS and leaves $# unchanged,
        # which spins this loop FOREVER under `set -uo pipefail` (no -e). A
        # release-path script that HANGS is worse than one that answers wrongly:
        # the cutter gets no verdict and no error, only a stopped terminal.
        # Found by the fixture arm below passing `--marker` with no value — the
        # arm was written for a different defect and caught this one.
        --cut-ref)
            [ $# -ge 2 ] || { echo "fail:must-ship:missing-value"
                echo "  --cut-ref needs a ref; nothing was examined" >&2; exit 0; }
            CUT_REF="$2"; shift 2 ;;
        --marker)
            [ $# -ge 2 ] || { echo "fail:must-ship:missing-value"
                echo "  --marker needs a value; nothing was examined" >&2; exit 0; }
            MARKER="$2"; shift 2 ;;
        -h|--help)
            echo "usage: check-must-ship-rows.sh [--cut-ref <ref>] [--marker <value>]" >&2
            exit 0 ;;
        *)
            # `fail:` and exit 0, matching this file's other refusal
            # (unreadable-ledger): the caller made an error, and NO verdict about
            # any tree is printed, because a verdict here would be about the
            # wrong one. Exit 0 keeps the advisory unable to block a cut even
            # when invoked wrongly.
            echo "fail:must-ship:unknown-argument"
            echo "  unrecognised argument: $1" >&2
            echo "  Nothing was examined, and NO verdict was printed: the run you asked for" >&2
            echo "  is not the run this would have made. It would have answered about HEAD." >&2
            echo "  The ref goes behind --cut-ref:" >&2
            echo "      scripts/check-must-ship-rows.sh --cut-ref $1" >&2
            exit 0 ;;
    esac
done

command -v jq >/dev/null 2>&1 || {
    echo "skipped:must-ship:no-jq"
    echo "  jq is absent; the ledger projection could not be read" >&2
    exit 0
}

. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(resolve_plan_binary 2>/dev/null)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "skipped:must-ship:no-plan-binary"
    echo "  tillandsias-plan not built; the must-ship pass did not run" >&2
    exit 0
fi

if ! git rev-parse --verify "$CUT_REF" >/dev/null 2>&1; then
    echo "skipped:must-ship:no-cut-ref"
    echo "  note: ref '$CUT_REF' unavailable — nothing was examined" >&2
    exit 0
fi

# FALSIFY THE INSTRUMENT BEFORE TRUSTING A ZERO (see the stale-binary note
# above). A throwaway index with one marked row: if the field does not survive
# this binary's projection, every real answer below would be a silent zero.
_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/must-ship-probe.XXXXXX")"
printf 'packets:\n  - packet_id: probe\n    order: 9999-zzzz\n    status: ready\n    kind: bug\n    must_ship: next\n    title: |\n      probe\n' > "$_probe_dir/index.yaml"
_probe_saw="$("$PLAN" --index "$_probe_dir/index.yaml" query --status ready --limit 1 --json 2>/dev/null \
    | jq -r '.[0].must_ship // "ABSENT"' 2>/dev/null)"
rm -rf "$_probe_dir"
if [ "${_probe_saw:-ABSENT}" != "next" ]; then
    echo "skipped:must-ship:stale-plan-binary"
    echo "  $PLAN does not project must_ship (probe read '${_probe_saw:-ABSENT}')." >&2
    echo "  A zero from this binary would mean 'cannot see marks', not 'no marks'." >&2
    echo "  Remedy, BOTH halves — the build alone is often a no-op on a current" >&2
    echo "  checkout (0.08s, already built) and what is actually missing is the STAMP:" >&2
    echo "      cargo build --release -p tillandsias-plan && scripts/check-plan-binary-current.sh" >&2
    echo "  Running only the first half shows nothing change and reads as a broken remedy." >&2
    exit 0
fi

rows_json="$("$PLAN" query --status ready --limit 999 --json 2>/dev/null; \
             "$PLAN" query --status in_progress --limit 999 --json 2>/dev/null; \
             "$PLAN" query --status completed --limit 999 --json 2>/dev/null; \
             "$PLAN" query --status implemented --limit 999 --json 2>/dev/null)" || rows_json=""
if [ -z "$rows_json" ]; then
    # An EMPTY RESULT and an UNREADABLE LEDGER are different facts. query prints
    # `[]` for "no matches" and nothing at all when it could not read.
    echo "fail:must-ship:unreadable-ledger"
    echo "  '$PLAN query --tag $MARKER --json' produced no output — the ledger could not be read." >&2
    echo "  This is NOT 'no rows are marked': that answer is the two characters []." >&2
    exit 0
fi

marked=0
outstanding=0
report=""
while IFS=$'\t' read -r order pid status; do
    [ -n "${order:-}" ] || continue
    marked=$((marked + 1))
    # Subject-anchored: `type(order): …`. A body MENTION is not a fix.
    hits="$(git log --format='%s' "$CUT_REF" 2>/dev/null \
        | awk -v o="$order" 'index($0, "(" ) && $0 ~ ("^[a-z]+\\([^)]*" o "[^)]*\\)") {n++} END{print n+0}')"
    if [ "${hits:-0}" -eq 0 ]; then
        outstanding=$((outstanding + 1))
        report="${report}  OUTSTANDING  ${order}  [${status}]  ${pid}
      no commit in '${CUT_REF}' has a subject naming this order
"
    else
        report="${report}  present      ${order}  [${status}]  ${hits} commit(s) in '${CUT_REF}'
"
    fi
done < <(printf '%s' "$rows_json" | jq -r --arg m "$MARKER" \
    '.[] | select((.must_ship // "") != "") | "\(.order)\t\(.packet_id)\t\(.status)"' 2>/dev/null | sort -u)

if [ "$marked" -eq 0 ]; then
    echo "ok:must-ship:0 outstanding of 0 marked"
    exit 0
fi

if [ "$outstanding" -eq 0 ]; then
    # NEGATIVE CONTROL (criterion 3): a clean cut prints ONE line and does not
    # become noise. The per-row detail stays on stderr behind the verdict.
    echo "ok:must-ship:0 outstanding of ${marked} marked"
    printf '%s' "$report" >&2
    exit 0
fi

echo "advisory:must-ship:${outstanding} outstanding of ${marked} marked"
printf '%s' "$report" >&2
echo "  These rows are marked '${MARKER}' and no commit in '${CUT_REF}' names them." >&2
echo "  ADVISORY (1218-25z3): it does not block the cut. Ship anyway if that is the" >&2
echo "  decision — the defect this closes was that nobody was TOLD, not that someone" >&2
echo "  overrode a warning. To clear a row, land its fix or drop the marker tag." >&2
exit 0

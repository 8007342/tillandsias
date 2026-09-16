#!/usr/bin/env bash
# @trace spec:versioning, spec:ci-release
#
# check-ledger-distillation.sh — report when the README release ledger has grown
# past the size its own distillation policy names.
#
# Order 914-nkc4. ADVISORY: exits 0 on every verdict, including `due:`.
#
# ── WHY IT EXISTS ───────────────────────────────────────────────────────────
#
# The policy is documented in TWO places — skills/merge-to-main-and-release
# ("when the table exceeds ~10 rows, distill the oldest rows into the
# `*Older releases*` line") and README.md's own preamble — and the destination
# line is already present in the table. So the mechanism is fully described and
# has somewhere to put the result.
#
# NOTHING RAN IT. It was a sentence in a runbook step that a human or an agent
# was expected to notice while doing something else. MEASURED 2026-08-26: the
# table stood at 19 rows, nearly double its own threshold, and no row had ever
# been distilled. 914-nkc4's deliverable is explicit — "either the policy is
# enforced by something, or the ~10-row trigger is restated as the advisory it
# currently is". This is the first branch: something now runs it.
#
# THE POLICY HAS SINCE FIRED TWICE (66d615e3f, f51aa955e) and the table is back
# under threshold. That does not close the row and this script is not
# retrospective decoration: both firings happened because somebody noticed,
# which is the condition 914-nkc4 names. What changes here is that noticing is
# no longer required.
#
# ── STRENGTH: REPORT, NOT BLOCK ─────────────────────────────────────────────
#
# Deliberate, and the same ruling 1218-25z3 carries for its sibling advisory: an
# over-long ledger costs a long README, never a false verdict, and a cut must
# never be refused over table length. The asymmetry that decides it — an ignored
# report costs one oversized table and LEAVES EVIDENCE in the cut log, while a
# bypassed block teaches a bypass that is global.
#
# ── VERDICTS (stdout, last line) ────────────────────────────────────────────
#   ok:ledger-distillation:<n>-rows:threshold=<t>      at or under threshold
#   due:ledger-distillation:<n>-rows:threshold=<t>     over — distill the oldest
#   skipped:ledger-distillation:no-readme:<ref>        README unreadable at <ref>
#   fail:ledger-distillation:unknown-argument:<arg>    nothing was examined
#   fail:ledger-distillation:missing-value:<flag>      nothing was examined
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# The documented trigger is "~10 rows". The tilde is deliberate in prose and
# useless in a comparison, so the threshold is pinned here and the runbook text
# points at this file rather than restating a number that would drift.
THRESHOLD=10
REF="HEAD"

# An unrecognised argument EXAMINES NOTHING and says so (yoga-silverblue,
# 1218-25z3, 2026-09-16): a `*) shift ;;` arm silently discards a typo'd flag
# and the run proceeds against the default, printing a clean verdict about a
# tree nobody asked about. Both flags also REQUIRE their value — `shift 2` with
# one argument left fails while leaving the count unchanged, which under
# `set -uo pipefail` with no `-e` spins forever, and a release-path script that
# HANGS is worse than one that answers wrongly: no verdict, no error, nothing
# to read afterwards.
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)
            [ $# -ge 2 ] || { echo "fail:ledger-distillation:missing-value:--ref"; echo "  --ref needs a value; nothing was examined" >&2; exit 0; }
            REF="$2"; shift 2 ;;
        --threshold)
            [ $# -ge 2 ] || { echo "fail:ledger-distillation:missing-value:--threshold"; echo "  --threshold needs a value; nothing was examined" >&2; exit 0; }
            THRESHOLD="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
        *)
            echo "fail:ledger-distillation:unknown-argument:$1"
            echo "  nothing was examined. usage: $(basename "${BASH_SOURCE[0]}") [--ref <ref>] [--threshold <n>]" >&2
            exit 0 ;;
    esac
done

case "$THRESHOLD" in
    ''|*[!0-9]*) echo "fail:ledger-distillation:missing-value:--threshold"; echo "  --threshold must be a non-negative integer" >&2; exit 0 ;;
esac

# READ THE REF, NOT THE WORKTREE, so the check can be pointed at the tree being
# cut — and so it has a positive control. A check that only ever reports `ok:`
# on a healthy tree is indistinguishable from one that is broken.
if [ "$REF" = "HEAD" ] && [ -f "$ROOT/README.md" ]; then
    readme="$(cat "$ROOT/README.md" 2>/dev/null)"
else
    readme="$(git -C "$ROOT" show "$REF:README.md" 2>/dev/null)"
fi
if [ -z "$readme" ]; then
    echo "skipped:ledger-distillation:no-readme:$REF"
    echo "  README.md could not be read at '$REF'; NOTHING was counted. A zero here" >&2
    echo "  would mean 'could not look', not 'no rows'." >&2
    exit 0
fi

# One table row per release OR per distilled span. The policy is about TABLE
# LENGTH — what a reader scrolls past — so a span counts once however many
# releases it covers, which is the whole point of distilling it.
rows="$(printf '%s\n' "$readme" | grep -cE '^\| v[0-9]')"
spans="$(printf '%s\n' "$readme" | grep -cE '^\| v[0-9].*DISTILLED')"

if [ "$rows" -gt "$THRESHOLD" ]; then
    echo "  the README release ledger has $rows rows; its own policy distills past $THRESHOLD." >&2
    echo "  $spans row(s) are already DISTILLED spans." >&2
    echo "  Distill the oldest into the '*Older releases*' line (the destination is already there)." >&2
    echo "  ADVISORY (914-nkc4): it does not block a cut. Table length costs a long README," >&2
    echo "  never a false verdict." >&2
    echo "due:ledger-distillation:$rows-rows:threshold=$THRESHOLD"
    exit 0
fi

echo "ok:ledger-distillation:$rows-rows:threshold=$THRESHOLD"
exit 0

#!/usr/bin/env bash
# @trace spec:ci-release, plan 1354-uv4e
#
# census-sigpipe-verdict-pipelines.sh — how many verdict pipelines that SIGPIPE
# can decide does the STANDING corpus carry?
#
# WHY THE STANDING SET GOES UNCOUNTED, and why that is not a defect in the
# decider. `check-sigpipe-verdict-pipelines-added.sh` is DIFF-SCOPED by design
# and says so in its own output: "it flags ONLY pipelines added in this change,
# never the existing corpus." That construction is right — refusing a push over
# lines it did not write is how a guard becomes something people route around.
# It also means nothing counts what is already there. This does.
#
# Same shape as 1304-wbb2 / 1333-jpq5: a correctly-built diff-scoped guard, and
# a standing population nobody has a number for.
#
# ── IT RUNS THE DECIDER. IT DOES NOT REIMPLEMENT IT. ────────────────────────
#
# The decider already carries a careful definition of "verdict pipeline": an
# early-exiting consumer, a producer that can still be writing, a file that sets
# pipefail, and a VERDICT CONTEXT — which since 1307-ermc means a leading
# if/while/until/elif OR `&&`/`||` after the consumer. Rewriting that here would
# create two definitions of one term, and the census would eventually disagree
# with the guard whose population it claims to measure. So this script drives
# the decider through its own `TILLANDSIAS_SIGPIPE_BASE` seam, pointed at the
# EMPTY TREE: every line then reads as "added", and the diff-scoped guard
# becomes a whole-corpus census without a line of duplicated logic.
#
# THE SEAM WAS ALREADY THERE for the decider's own fixture. Using it this way is
# not a workaround; it is the same override answering a different question.
#
# ── THE CONTROL THAT MAKES THE NUMBER MEAN SOMETHING ────────────────────────
#
# A count from a mode nobody has checked is not a measurement. Before trusting
# this, the empty-tree mode was run against four hand-written cases — one real
# verdict pipeline, one here-string, one non-verdict context, one carrying a
# `# sigpipe-ok:` marker — and flagged EXACTLY the first. That control lives in
# scripts/test-census-sigpipe-verdict-pipelines.sh and runs every time.
#
# It also corrected a wrong inference of mine. The decider's header records 167
# early-exit greps narrowing to 9 in scope, so when this census answered a
# number close to a crude grep's, I suspected the verdict filter was not
# applying. It was: that 167->9 ratio is measured over ONE WEEK OF ADDED LINES,
# a different population from the standing corpus. The instrument was right and
# the reasoning about it was wrong — which is the argument for the control
# rather than for the suspicion.
#
# ── REPORT, NEVER A GATE. Exit is ALWAYS 0. ────────────────────────────────
#
# The standing set is large and nearly all of it is benign: the race needs the
# producer to still be writing when the consumer exits, and the common shape is
# `printf '%s' "$short_var" | grep -q`, whose producer emits a SHA or a branch
# name. Reddening the fleet over history nobody has triaged is the 699-dycj /
# 660-ryhn failure, and it would make the conversion less likely, not more.
# The number is for planning a sweep, not for failing a build.
#
# Grammar (final line on stdout, nothing after it):
#   ^ok:sigpipe-verdict-standing:[0-9]+ sites in [0-9]+ files$
#
# Usage: scripts/census-sigpipe-verdict-pipelines.sh [--list]

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

DECIDER="scripts/check-sigpipe-verdict-pipelines-added.sh"
list=0
[ "${1:-}" = "--list" ] && list=1

if [ ! -f "$DECIDER" ]; then
    echo "ok:sigpipe-verdict-standing:0 sites in 0 files"
    echo "  note: $DECIDER absent — nothing to drive" >&2
    exit 0
fi

# The empty tree. Derived, never hardcoded: the well-known
# 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is correct for SHA-1 repositories and
# wrong for SHA-256 ones, and a census that silently measures nothing on a
# future repo format is the failure this whole family is about.
EMPTY="$(git hash-object -t tree /dev/null 2>/dev/null)"
if [ -z "$EMPTY" ]; then
    echo "ok:sigpipe-verdict-standing:0 sites in 0 files"
    echo "  note: could not derive the empty-tree object — census not run" >&2
    exit 0
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/sigpipe-census.XXXXXX")" || exit 2
trap 'rm -f "$TMP"' EXIT

# The decider exits 1 when it finds violations, which here is the EXPECTED
# outcome rather than a failure — the status is deliberately discarded and the
# verdict below is computed from its output.
TILLANDSIAS_SIGPIPE_BASE="$EMPTY" bash "$DECIDER" >"$TMP" 2>&1 || true

sites="$(grep -c '^REFUSED:' "$TMP" 2>/dev/null || echo 0)"
files="$(grep '^REFUSED:' "$TMP" 2>/dev/null | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"

if [ "$list" -eq 1 ] && [ "$sites" -gt 0 ]; then
    grep '^REFUSED:' "$TMP" | awk '{print $2}' | sort | uniq -c | sort -rn
fi

echo "ok:sigpipe-verdict-standing:$sites sites in $files files"
exit 0

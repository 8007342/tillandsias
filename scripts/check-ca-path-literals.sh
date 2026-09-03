#!/usr/bin/env bash
# @trace order:998-qrwu, order:975-rsgm
#
# check-ca-path-literals.sh — the `/tmp/tillandsias-ca` literal count may not
# GROW while the single-sourcing (998-qrwu) and the relocation (998-3z6g) are
# pending.
#
# WHY A RATCHET RATHER THAN A REFUSAL. The path is a literal in 36 places across
# 16 files today, measured 2026-09-03. Redding the trunk on that standing debt
# would switch this off within a day — the failure the fleet has already
# demonstrated twice this week. What a ratchet CAN do is stop the number rising
# while the migration is planned, so 998-qrwu has a fixed target instead of a
# moving one.
#
# WHY IT MATTERS THAT IT NOT GROW. 975-rsgm's remaining half moves this
# directory off /tmp. Every literal that exists at that moment is a site that
# must move with it, and a missed one fails in the quietest possible way: it
# points at a directory that is not there, on a recovery path that only runs
# when something is already wrong. That is where nobody is watching.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:ca-path-literals:[0-9]+ of [0-9]+|violation:ca-path-literals-grew:[0-9]+ of [0-9]+)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The ratchet. Lower this when 998-qrwu removes literals; it must never rise.
BASELINE="${TILLANDSIAS_CA_PATH_LITERAL_BASELINE:-38}"

# The declaration itself is exempt once it exists — that is the ONE place the
# path is allowed to be written, and 998-qrwu creates it.
# COUNT OCCURRENCES, NOT LINES. A line can carry the literal twice, and the
# unit that matters is the number of SITES that must move — not the number of
# lines they sit on. My first baseline was a line count (36) and the ratchet
# refused on its own first run at 37; the true occurrence count is 38 once the guard's own mentions are excluded. Three
# numbers for one quantity, which is the measurement defect this repository has
# been finding all week, produced here by choosing the convenient unit.
count="$(grep -rho '/tmp/tillandsias-ca' \
            --exclude=check-ca-path-literals.sh \
            --exclude=ca_path.rs \
            crates/ scripts/ images/ 2>/dev/null | wc -l | tr -d ' ')"

if [ "$count" -gt "$BASELINE" ]; then
    echo "violation:ca-path-literals-grew:$count of $BASELINE"
    {
        echo "  A new literal '/tmp/tillandsias-ca' was added. That path is being"
        echo "  single-sourced (998-qrwu) so it can be moved off /tmp (998-3z6g),"
        echo "  and every literal is a site that must move with it — a missed one"
        echo "  points at a directory that is not there, on a recovery path that"
        echo "  only runs when something is already wrong."
        echo "  Read the path from the shared declaration instead of restating it."
    } >&2
    exit 1
fi

echo "ok:ca-path-literals:$count of $BASELINE"

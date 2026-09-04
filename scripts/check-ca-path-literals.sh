#!/usr/bin/env bash
# @trace order:998-qrwu, order:975-rsgm
#
# check-ca-path-literals.sh — the `/tmp/tillandsias-ca` literal count may not
# GROW. It is now a REGRESSION PIN against the old path coming back, not a
# ratchet over pending debt: 998-qrwu single-sourced the path and 998-3z6g
# moved it off /tmp, and both have landed.
#
# WHAT THIS GUARD DOES NOT WATCH, stated because two hosts assumed otherwise on
# 2026-09-04: its subject is the PRE-migration literal `/tmp/tillandsias-ca`.
# It has never watched the post-migration CA directory, and it has never
# watched the state ROOT those paths share. A duplicate of the root got past it
# for that reason — there was no guard to get past. The root has its own guard
# (1027-539s); do not read a green verdict here as coverage of either.
#
# WHY A RATCHET RATHER THAN A REFUSAL, and it is history now. The path was a
# literal in 38 places across 16 files, measured 2026-09-03. Reddening the
# trunk on that standing debt would have switched this off within a day, so the
# ratchet held the number still while 998-qrwu removed them.
#
# WHY IT MATTERED THAT IT NOT GROW. 975-rsgm had to move this directory off
# /tmp, and every literal alive at that moment was a site that had to move with
# it. A missed one fails in the quietest possible way: it points at a directory
# that is not there, on a recovery path that only runs when something is
# already wrong. That is where nobody is watching.
#
# THE SURVIVING OCCURRENCE, and it is not debt. BASELINE is 1, and the one hit
# is in images/default/cheatsheets/runtime/low-end-cpu-inference-floor.md,
# where the sentence explicitly says the cause is PAST — it explains a symptom
# (every pull returns 000) by naming the volatile path that used to cause it.
# Rewriting that literal to the new path would make a true account false: the
# proxy never failed because the state dir was wiped, it failed because /tmp
# was. This is NOT a blanket exemption — the occurrence is correct only for as
# long as its surrounding sentence keeps saying it is history. If the count
# rises, the new one is almost certainly not.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:ca-path-literals:[0-9]+ of [0-9]+|violation:ca-path-literals-grew:[0-9]+ of [0-9]+)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The ratchet. Lower this when 998-qrwu removes literals; it must never rise.
BASELINE="${TILLANDSIAS_CA_PATH_LITERAL_BASELINE:-1}"

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
            --exclude=ca-path.txt \
            --exclude=lib-ca-path.sh \
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

#!/usr/bin/env bash
# @trace spec:ci-release, plan 1349-tdpg
#
# census-admitted-missing-evidence.sh — how old is our self-flagged evidence
# debt?
#
# THE QUESTION, and why it is not covered by anything else here. This tree has
# ratchets for ghost traces, unreferenced added tests, litmus reachability and
# unbound litmus. Every one of them checks WIRING: is this reachable, is it
# referenced, does it run. Not one can check whether a stated PREMISE was ever
# true, and all of them cleared the specimen that produced this row.
#
# THE SPECIMEN (591-33s6, tray page cap). A constant carried this comment for
# seven weeks: "Nobody has yet measured a real fleet repo count against a real
# screen, so it stays at 10 until someone does." Nothing was wrong with that
# sentence. It was accurate, it was honest about its own status, it named its
# own missing evidence, and it sat in the file everyone touching the feature
# read. The operator eventually measured it in one minute and the premise was
# false — the shell scrolls — so a constant shaping the product on three
# platforms had been resting on an inference nobody had checked.
#
# WHY IT AGED IN PLAIN SIGHT, in esme-windows' words, which are the sharpest
# statement of the problem: SELF-FLAGGED EVIDENCE DEBT HAS NO OWNER BY
# CONSTRUCTION. The person who wrote "nobody has measured this" was being
# honest, and honesty is not a task. Nothing assigns it, nothing ages it,
# nothing ever returns to it. The other failures that week were wrong claims
# asserted confidently; this was a CORRECT claim, correctly flagged as
# unverified, that nobody actioned.
#
# WHAT THIS PRINTS IS AN AGE, NOT A SENTENCE. A note saying "unmeasured" is a
# fact about the code. The same note being 214 days old is a fact about US, and
# only the second one is actionable. Oldest first, for the same reason.
#
# ── THE FLOOR, stated because a census that hides its floor is worse than none
# ── (and the row requires it stated here and beside the cheatsheet specimen):
#
#   IT FINDS ONLY PREMISES SOMEBODY FLAGGED. An assumption nobody wrote down is
#   invisible to it, and those are the dangerous ones — the tray cap's own
#   author DID flag it, which is why this instrument would have caught that
#   case and why it says nothing about the assumptions that never reached a
#   comment. This is a floor, not a solution. Do not read a count of 0 as "no
#   unmeasured premises"; read it as "nobody admitted one".
#
#   It is also ANTI-CORRELATED WITH CARE in the same way the mention-count
#   heuristic was: the more scrupulously someone documents their uncertainty,
#   the more they appear here. That is a reason to keep it a report and never a
#   ranking of people.
#
#   PRECISION, MEASURED ON THIS TREE 2026-09-22 RATHER THAN ASSERTED — because
#   shipping an untriaged count is the exact mistake this row exists to name.
#   The census answered 6; reading all six in context, ONE is real evidence
#   debt:
#
#     genuine   images/inference/engine-tuning.sh:83 — ROCm/Vulkan tuning
#               "Unmeasured on this host", holding a conservative default.
#               Real debt, and safely handled: the unmeasured path is not taken.
#
#   The other five are residue in two classes, both worth knowing because
#   neither is a bug in the comment that produced them:
#
#     MAXIMS      A general rule phrased with a subject who has not checked —
#                 "a guard nobody has watched fail is a guard nobody has
#                 tested"; "indistinguishable from a fabricated one until
#                 somebody checks". These defer nothing; they explain why a
#                 mechanism exists. Three hits.
#     POST-MORTEMS  A comment QUOTING a now-measured admission to record how it
#                 aged — menu_state.rs quoting the tray cap's own "nobody has
#                 yet measured". The premise has since been measured and the
#                 code fixed, so the debt is discharged and only the story
#                 remains. Two hits.
#
#   So roughly one in six. That is a POOR RATIO and an ACCEPTABLE ONE for a
#   report, because six lines get read and sixty-four do not — the first
#   pattern set answered 64 on this tree and would have been ignored wholesale.
#   The residue is left rather than pattern-matched away: narrowing far enough
#   to exclude a maxim would also exclude the specimen this row was filed from,
#   which is phrased identically. A human triaging six lines is the design, not
#   a shortfall in it.
#
# ── REPORT, NEVER A GATE. Exit is ALWAYS 0. ────────────────────────────────
#
# The reason is 1338-x5rq's 187 suppressions. This instrument matches honest,
# correct, deliberately-deferred notes, because that is exactly what it looks
# for. Gate on it and the rational response is to stop writing the admission —
# which destroys the only signal it has and leaves the debt behind, now
# invisible. An instrument that punishes the behaviour it depends on eats
# itself.
#
# Grammar (final line on stdout, nothing after it):
#   ^ok:admitted-missing-evidence:[0-9]+ hits, oldest [0-9]+d$
#
# Usage: scripts/census-admitted-missing-evidence.sh [--root DIR] [--quiet]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
quiet=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)  ROOT="$2"; shift 2 ;;
        --quiet) quiet=1; shift ;;
        *)       shift ;;
    esac
done
cd "$ROOT" 2>/dev/null || { echo "ok:admitted-missing-evidence:0 hits, oldest 0d"; exit 0; }

# ── THE PATTERNS. ───────────────────────────────────────────────────────────
#
# Each one matches a CLAIM THAT DEFERS ITS OWN EVIDENCE, not a topic word. The
# distinction is the whole difference between this working and it returning
# noise, and the fixture's decoy exists to hold the line: a comment saying "we
# measured this and someone verified it" contains `measured`, `someone` and
# `verified` and admits nothing.
#
# So every pattern below carries its own NEGATION or DEFERRAL — "nobody has",
# "not yet", "until someone", "is assumed" — rather than the bare verb. A
# pattern of `measured` alone would match the decoy, the specimen, and every
# sentence in between.
#
# Deliberately NOT included:
#   * bare `TODO` / `FIXME` — thousands of them, and they are task debt, not
#     evidence debt. A TODO says "do this"; an admission says "I do not know
#     this". Only the second is what has no owner.
#   * the token `unverified` on its own — it is a live VERDICT PREFIX in
#     check-credential-channel.sh (`unverified:gh-credentials-store`), so
#     matching it bare would report the credential guard's own grammar as
#     evidence debt. Exactly the substring-inside-an-unrelated-word mistake
#     this fleet has now made four times in a day.
# MEASURED AND TIGHTENED, 2026-09-22, ON THE FIRST REAL RUN. The first pattern
# set answered 64 hits on this tree and MOST WERE NOT EVIDENCE DEBT. This repo's
# culture is writing about measurement discipline, so phrase-matching found the
# culture: "verified where it was written is not verified where it runs" is a
# maxim quoted in five files; "claiming an unmeasured win" is a warning against
# doing it; `unmeasured:<file>:<line>` is a live VERDICT GRAMMAR in
# lib-sigpipe-verdict.sh; "ATTESTED, NOT MEASURED" is a statement of fact about
# a limit, already handled. None defers any evidence.
#
# That is the header's own anti-correlation-with-care warning, arriving as a
# measurement instead of a prediction — and reporting 64 would have been this
# fleet's third instance in a day of counting PROSE ABOUT a thing as instances
# OF it (comments read as assert enforcement; comments read as verdict
# emitters). An instrument aimed at premises must not be satisfied by essays
# about premises.
#
# So every pattern now requires an ADMISSION ABOUT THIS CODE: a subject that has
# not done something, or a deferral to a future someone. Dropped deliberately:
#
#   bare `unmeasured`      — a verdict token and an adjective; matches maxims
#   `not verified`         — "the Containerfile is NOT verified here" is a
#                            statement about WHERE work happens, not an admission
#   `this is an assumption`— overwhelmingly used to NAME a known assumption that
#                            the same comment then discharges
#
# Kept: forms where a person says the checking has not happened. These cannot be
# satisfied by a maxim, because a maxim has no subject who failed to measure.
PATTERNS='nobody has (yet )?(measured|checked|verified|tested)'
PATTERNS="$PATTERNS|no ?one has (yet )?(measured|checked|verified|tested)"
PATTERNS="$PATTERNS|(has|have) not (yet )?been (measured|checked|benchmarked)"
PATTERNS="$PATTERNS|(is|are|was|were) not yet (measured|checked|benchmarked)"
PATTERNS="$PATTERNS|until (someone|somebody) (does|checks|measures|tests)"
PATTERNS="$PATTERNS|assumed,? (not|rather than) measured"
PATTERNS="$PATTERNS|unmeasured on this host"
PATTERNS="$PATTERNS|(we|i) (assume|am assuming) (this|that|it) (is|will|does)"

# Comment-bearing sources only. A match in a .md prose document is usually
# describing the problem rather than committing it — this file would otherwise
# report itself, which is the self-detection shape that has already cost a
# false reading today.
FILES="$(git ls-files -- '*.rs' '*.sh' '*.yaml' '*.yml' '*.toml' 2>/dev/null)"
[ -n "$FILES" ] || FILES="$(find . -type f \( -name '*.rs' -o -name '*.sh' -o -name '*.yaml' \) -not -path './.git/*' 2>/dev/null)"

now="$(date +%s)"
rows=""
prev_f=""; prev_line=-99; group_days=0
hits=0
oldest=0

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    # Skip this census and its fixture: both necessarily QUOTE the patterns, and
    # an instrument that counts its own definition is measuring itself.
    case "$f" in
        */census-admitted-missing-evidence.sh|*/test-census-admitted-missing-evidence.sh) continue ;;
    esac
    while IFS=: read -r lineno text; do
        [ -n "$lineno" ] || continue
        # Only inside a comment. A string literal that happens to contain the
        # phrase is not an admission by the author about the code.
        case "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')" in
            '//'*|'#'*|'///'*|'*'*|'/*'*) ;;
            *) continue ;;
        esac
        # git blame for the age. A line with no blame (uncommitted) is age 0 and
        # still counted — it is an admission that exists, just not yet aged.
        ts="$(git blame -L "$lineno,$lineno" --porcelain -- "$f" 2>/dev/null \
              | sed -n 's/^author-time //p' | head -1)"
        if [ -n "$ts" ]; then
            days=$(( (now - ts) / 86400 ))
        else
            days=0
        fi
        # ── ONE ADMISSION, NOT ONE LINE. ───────────────────────────────
        # Caught by the positive control before this ever ran on the repo: the
        # specimen comment is TWO lines ("Nobody has yet measured…" / "…until
        # someone does") and is ONE admission. Counting lines makes the census
        # report a number that rises with how carefully someone wrapped their
        # prose — the same anti-correlation with care that broke the
        # mention-count heuristic, reintroduced through formatting.
        #
        # Matching lines within 3 of each other in the same file are one hit.
        # The group keeps the OLDEST age, because an admission is as old as the
        # day it was first admitted, not as old as its most recent rewording.
        if [ "$f" = "$prev_f" ] && [ $((lineno - prev_line)) -le 3 ]; then
            prev_line="$lineno"
            [ "$days" -gt "$group_days" ] && group_days="$days"
            continue
        fi
        prev_f="$f"; prev_line="$lineno"; group_days="$days"
        [ "$days" -gt "$oldest" ] && oldest="$days"
        hits=$((hits + 1))
        rows="$rows$(printf '%08d\t%dd\t%s:%s\t%s' "$days" "$days" "$f" "$lineno" \
            "$(printf '%s' "$text" | sed 's/^[[:space:]]*//' | cut -c1-100)")
"
    done < <(grep -nEi "$PATTERNS" -- "$f" 2>/dev/null)
done <<< "$FILES"

if [ "$quiet" -eq 0 ] && [ "$hits" -gt 0 ]; then
    # OLDEST FIRST. The age is the actionable field, so the listing is ordered
    # by it; burying the oldest debt under the newest is the same information in
    # an order nobody acts on.
    printf '%s' "$rows" | sort -rn | cut -f2-
fi

echo "ok:admitted-missing-evidence:$hits hits, oldest ${oldest}d"
exit 0

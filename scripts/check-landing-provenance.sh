#!/usr/bin/env bash
# @trace order:1315-4a7j, spec:ci-release
#
# check-landing-provenance.sh — HOW DOES INTEGRATION ACTUALLY ARRIVE?
#
# WHY THIS EXISTS AND WHY IT IS NOT A GUARD. 1315-4a7j opens work/<order> as the
# ungated lane a host commits and pushes to, and the operator was explicit that
# this phase is MIGRATION, NOT ENFORCEMENT: "adding new hard rules would make a
# bunch of agents crash and suddenly start failing hard on ways they already
# know how to work". Nothing new refuses. The preferred workflow arrives as
# affordances, and enforcement becomes a later, operator-triggered decision.
#
# THE TRIGGER IS A NUMBER, WHICH IS WHAT THIS PRINTS. When queue landings are
# the majority of CODE landings for a week, the operator can flip to
# enforcement on measured behaviour rather than on a preference — and, just as
# importantly, can see if they are NOT the majority and know the migration has
# not taken.
#
# IT REFUSES NOTHING, EVER. Exit 0 on every classification; the only non-zero
# exits are "I could not look" (no repo, no ref), which must not read as "the
# fleet is behaving".
#
#   landing-provenance:<window>:queue=<n> plan=<n> relay=<n> direct=<n>
#
# CLASSIFICATION IS BY FIRST PARENT, deliberately. Walking every commit would
# count the contents of a merged branch as separate landings and inflate
# whichever lane the author happened to commit in; the first-parent walk counts
# INTEGRATION EVENTS, which is the question.
set -uo pipefail
# TILLANDSIAS_PROVENANCE_REPO is the test seam. Without it this script cd's to
# its OWN checkout, so a fixture that runs it from a scaffold repository silently
# measures the real fleet history instead — which is what the first version of
# arm 5 did, reporting direct=766 for a four-commit scaffold.
if [ -n "${TILLANDSIAS_PROVENANCE_REPO:-}" ]; then
    cd "$TILLANDSIAS_PROVENANCE_REPO" || exit 2
else
    cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
fi

WINDOW="${1:-7.days}"
REF="${TILLANDSIAS_PROVENANCE_REF:-origin/linux-next}"

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "blocked:landing-provenance:not-a-git-repo"; exit 2; }
git rev-parse --verify "$REF" >/dev/null 2>&1 || {
    echo "blocked:landing-provenance:no-ref:$REF"; exit 2; }

queue=0; plan=0; relay=0; direct=0

# %H<TAB>%s over the first-parent walk. A landing with no subject is still a
# landing; it falls to `direct`, which is the honest default for "not
# recognisably one of the named lanes".
while IFS=$'\t' read -r sha subj; do
    [ -n "${sha:-}" ] || continue

    # A PR merge is the queue's signature. GitHub writes "Merge pull request
    # #<n>", and the landing queue's own merges name the work ref they took.
    case "$subj" in
        "Merge pull request "*|*"from work/"*|"land("*|"queue("*)
            queue=$((queue + 1)); continue ;;
    esac

    # A relay is a platform branch carrying another branch's work across.
    case "$subj" in
        "relay("*|"Merge remote-tracking branch "*)
            relay=$((relay + 1)); continue ;;
    esac

    # PLAN-ONLY IS DECIDED BY CONTENT, NOT BY SUBJECT. A commit whose every
    # changed path is under plan/ is the fragment lane whatever it calls itself,
    # and a commit that merely SAYS plan( ) while touching scripts/ is not. The
    # subject is the author's claim; the paths are what happened.
    changed="$(git show --first-parent --name-only --format='' "$sha" 2>/dev/null | grep -c . || true)"
    nonplan="$(git show --first-parent --name-only --format='' "$sha" 2>/dev/null | grep -vc '^plan/' || true)"
    if [ "${changed:-0}" -gt 0 ] && [ "${nonplan:-0}" -eq 0 ]; then
        plan=$((plan + 1)); continue
    fi

    direct=$((direct + 1))
done < <(git log --first-parent --since="$WINDOW" --format='%H%x09%s' "$REF" 2>/dev/null)

echo "landing-provenance:${WINDOW}:queue=${queue} plan=${plan} relay=${relay} direct=${direct}"

# THE READING RULE, PRINTED WITH THE NUMBER so it cannot be applied after the
# fact to whatever the number turned out to be (the "publish the reading rule
# before the measurement" discipline). Code landings are queue + direct: plan
# fragments do not race and relays are a platform branch's own traffic, so
# neither belongs in the ratio the flip depends on.
_code=$((queue + direct))
if [ "$_code" -gt 0 ]; then
    echo "  code landings: queue=${queue} direct=${direct} of ${_code} — the flip to enforcement wants queue > direct, sustained for a week"
else
    echo "  code landings: none in this window — the ratio is undefined, which is not the same as favourable"
fi
exit 0

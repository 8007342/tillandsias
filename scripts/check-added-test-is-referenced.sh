#!/usr/bin/env bash
# @trace spec:ci-release, plan 1325-ygq5
#
# check-added-test-is-referenced.sh — name, at push time, a test this push ADDS
# that nothing which runs on its own can fail because of.
#
# THE RULE IS ONE SENTENCE AND IT IS ORGAN-INDEPENDENT:
#   A TEST IS NOT DONE UNTIL SOMETHING THAT RUNS ON ITS OWN CAN FAIL BECAUSE OF IT.
# The artifact type changes only which file you edit to make that true.
#
# WHY THE AUTHOR IS THE ONE PERSON WHO CANNOT SEE IT. Both organs' artifacts run
# green when invoked by hand, which is how an author checks. The file states its
# own spec and phase in its frontmatter (litmus) or prints its own ok: line
# (shell), so everything the author looks at says the test is real. Only the
# thing that never ran — the suite, the gate — knows, and it reports the absence
# as a SMALLER TOTAL rather than as an error. A smaller total is not a signal.
#
# TWO SPECIMENS, SAME HOST, SAME DAY (2026-09-20/21, pirria):
#   litmus:installer-reprovisions-on-install was written into
#   openspec/litmus-tests/ and never added to openspec/litmus-bindings.yaml. A
#   ci-release suite ran to completion reporting 37 PASS / 3 FAIL with that test
#   in NEITHER number, and it was reported to the coordinator as verified.
#   scripts/test-reset-flags-are-accepted.sh was written hours later — to replace
#   an arm that counted MENTIONS of a flag instead of running the binary — and
#   committed with no step, no build.sh line and no binding. Its 7/7 could not
#   fail a gate. It replaced a test that could not fail FOR THE REASON IT NAMED
#   with one that could not fail AT ALL.
#
# The lesson from the first was filed against the ORGAN (a litmus yaml needs a
# bindings entry) rather than against the SHAPE, so it did not fire when the
# artifact was a shell script. This guard is filed against the shape.
#
# WHY NOT A CHECKLIST. A checklist at authoring time is read by the same person
# who has just finished the file and believes it is done. The decider has to
# fire on the diff, at push time, and NAME the artifact.
#
# DIFF-SCOPED BY CONSTRUCTION. Forty shell tests on trunk are unreferenced
# today; a guard that refuses them all turns one host's mistake into every
# host's red. This fires on what THIS PUSH ADDS — the construction
# check-added-fragments-parse.sh uses for the same reason (698-7n6q). You break
# it, your push is named. You inherit it, you are counted and not blamed.
#
# MIGRATION PHASE: WARN, carrying the standing count, so the flip to refusal is
# a decision someone makes AGAINST A NUMBER rather than on a date (operator
# direction). Set TILLANDSIAS_ADDED_TEST_REFERENCE_ENFORCE=1 to refuse.
#
# THE REFERENCE SURFACE IS DECLARED, NOT INLINE: scripts/test-reference-surfaces.manifest
# is the one definition both this guard and a reader use, and the verdict line
# carries its size so a fifth caller added tomorrow is visible rather than
# turning referenced tests into false positives (the packet's unscoreable).
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:added-test-referenced:[0-9]+ checked standing=[0-9]+ surfaces=[0-9]+|warn:added-test-unreferenced:[0-9]+ standing=[0-9]+ surfaces=[0-9]+|violation:added-test-unreferenced:[0-9]+)$
#
# Pinned by litmus:added-test-is-referenced-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

MANIFEST="scripts/test-reference-surfaces.manifest"
SHELL_GRANDFATHERED="scripts/unreferenced-grandfathered.txt"
LITMUS_GRANDFATHERED="openspec/litmus-tests/unbound-grandfathered.txt"
base_ref="${TILLANDSIAS_ADDED_TEST_BASE:-origin/linux-next}"
enforce="${TILLANDSIAS_ADDED_TEST_REFERENCE_ENFORCE:-0}"

if [ ! -f "$MANIFEST" ]; then
    # The surface is the whole meaning of "referenced". Without it this guard
    # would answer a different question than the one it claims to answer, and a
    # green would be a lie rather than a skip.
    echo "violation:added-test-unreferenced:0"
    echo "REFUSED: $MANIFEST is missing — 'referenced' has no definition, so this guard cannot answer." >&2
    exit 2
fi

# --- expand the declared surface -------------------------------------------
shell_surface=""
litmus_surface=""
surfaces=0
missing_patterns=""
while read -r organ pattern; do
    case "$organ" in ''|'#'*) continue ;; esac
    [ -n "$pattern" ] || continue
    surfaces=$((surfaces + 1))
    # Expand the glob HERE, and notice emptiness. A pattern matching nothing is
    # reported: silent expansion to zero files is the failure shape this whole
    # packet is about, one level up.
    matched=0
    for p in $pattern; do
        [ -e "$p" ] || continue
        matched=1
        case "$organ" in
            shell)  shell_surface="${shell_surface}${p}"$'\n' ;;
            litmus) litmus_surface="${litmus_surface}${p}"$'\n' ;;
        esac
    done
    [ "$matched" -eq 1 ] || missing_patterns="${missing_patterns}${organ} ${pattern}"$'\n'
done < "$MANIFEST"

if [ -n "$missing_patterns" ]; then
    {
        echo "NOTE: declared surface patterns that matched no file (the surface may have moved):"
        printf '   %s\n' "$(printf '%s' "$missing_patterns" | grep . | head -5)"
    } >&2
fi

# --- the standing count: the number the ratchet closes against ---------------
standing=0
for f in scripts/test-*.sh; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    if ! grep -rqlF -- "$b" $(printf '%s' "$shell_surface" | grep . | tr '\n' ' ') 2>/dev/null; then
        standing=$((standing + 1))
    fi
done

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "ok:added-test-referenced:0 checked standing=$standing surfaces=$surfaces"
    echo "  note: base ref '$base_ref' unavailable — added-test enforcement skipped" >&2
    exit 0
fi

# --- candidates: what THIS push adds ----------------------------------------
# ADDED only (A), never modified: editing an existing unreferenced test is not
# this packet's failure, and refusing it would make the standing forty radioactive
# to touch — exactly the fleet-wide red diff-scoping exists to avoid.
candidates="$(
    {
        git diff --name-only --diff-filter=A "$base_ref" -- 'scripts/test-*.sh' 'openspec/litmus-tests/*.yaml' 2>/dev/null
        git diff --name-only --cached --diff-filter=A -- 'scripts/test-*.sh' 'openspec/litmus-tests/*.yaml' 2>/dev/null
        git ls-files --others --exclude-standard -- 'scripts/test-*.sh' 'openspec/litmus-tests/*.yaml' 2>/dev/null
    } | sort -u
)"

_grandfathered() {   # $1=name  $2=list file
    [ -f "$2" ] || return 1
    # Strip trailing `# why` comments so a declared name with a reason still matches.
    grep -v '^[[:space:]]*#' "$2" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//' \
        | grep -qxF -- "$1"
}

checked=0
unreferenced=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    case "$f" in
        scripts/test-*.sh)
            needle="$(basename "$f")"
            surface="$shell_surface"
            organ="shell"
            grand="$SHELL_GRANDFATHERED"
            fix="add a scripts/gate-steps.d/*.step that runs it, a build.sh/local-ci.sh call, or a litmus yaml that invokes it"
            ;;
        openspec/litmus-tests/*.yaml)
            needle="$(grep -m1 '^name:' "$f" | sed 's/name: *//' | tr -d ' ')"
            [ -n "$needle" ] || continue          # declares no name — not this guard's question
            grep -qE '^phase: *retired *$' "$f" && continue
            surface="$litmus_surface"
            organ="litmus"
            grand="$LITMUS_GRANDFATHERED"
            fix="add '$needle' to its spec's litmus_tests: list in openspec/litmus-bindings.yaml"
            ;;
        *) continue ;;
    esac
    checked=$((checked + 1))

    # Never `printf | grep -q`: grep exiting at first match can SIGPIPE the
    # producer and, under pipefail, flip a MATCH into a failed pipeline —
    # measured live on yoga, three runs, three different phantom name sets.
    files="$(printf '%s' "$surface" | grep . | tr '\n' ' ')"
    if [ -n "$files" ] && grep -rqlF -- "$needle" $files 2>/dev/null; then
        continue
    fi
    if _grandfathered "$needle" "$grand"; then
        echo "  declared unreferenced (grandfathered): $needle" >&2
        continue
    fi
    unreferenced=$((unreferenced + 1))
    {
        echo "UNREFERENCED TEST ADDED: $f"
        echo "   nothing in the declared reference surface ($organ) names '$needle', so this test"
        echo "   CANNOT FAIL A GATE. Run by hand it will pass, and that pass means nothing."
        echo "   To make it real: $fix"
        echo "   To declare it deliberately unreferenced: add '$needle' to $grand with a reason."
    } >&2
done <<EOF
$candidates
EOF

if [ "$unreferenced" -gt 0 ]; then
    if [ "$enforce" = "1" ]; then
        echo "violation:added-test-unreferenced:$unreferenced"
        exit 1
    fi
    echo "warn:added-test-unreferenced:$unreferenced standing=$standing surfaces=$surfaces"
    echo "  WARN (migration phase): standing unreferenced shell tests = $standing. The flip to" >&2
    echo "  refusal is a decision made against that number — set" >&2
    echo "  TILLANDSIAS_ADDED_TEST_REFERENCE_ENFORCE=1 to refuse now." >&2
    exit 0
fi
echo "ok:added-test-referenced:$checked checked standing=$standing surfaces=$surfaces"
exit 0

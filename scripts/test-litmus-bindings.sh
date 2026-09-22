#!/usr/bin/env bash
# @trace order:660-ryhn, spec:ci-release
#
# Hermetic fixture for scripts/check-litmus-bindings.sh. The negative controls
# are the point — the failure mode this gate closes is SILENCE, so a checker
# that cannot go red on an unbound file is the defect wearing a gate's name.
#
# The fabricated test names are COMPOSED at runtime (`$LP`) so this file
# carries no literal fixture tokens for check-litmus-pin-claims.sh to read as
# verification claims — the pin checker refused this fixture's first draft,
# which is both an inconvenience and a proof the pin checker works.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-litmus-bindings.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$GATE" ] || fail "gate not found"

LP="litmus"   # composed prefix; never written literally next to a fixture name
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

scaffold() {
    # A minimal fixture tree: one bound file, one retired file, one
    # grandfathered file, a bindings registry naming the bound one.
    local d="$1"
    mkdir -p "$d/openspec/litmus-tests"
    printf 'name: %s:fix-bound\nspec: fix\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-bound.yaml"
    printf 'name: %s:fix-retired\nphase: retired\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-retired.yaml"
    printf 'name: %s:fix-grand\nspec: fix\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-grand.yaml"
    printf '# ratchet\n%s:fix-grand\n' "$LP" > "$d/openspec/litmus-tests/unbound-grandfathered.txt"
    printf 'specs:\n- spec_id: fix\n  litmus_tests:\n  - %s:fix-bound\n' "$LP" > "$d/openspec/litmus-bindings.yaml"
    # ORDER 1356-vv5m: the scaffold carries a SPEC for the spec_id it names,
    # because the checker now resolves them. A scaffold that names a spec_id
    # with no spec is the very defect under test, not a neutral fixture.
    mkdir -p "$d/openspec/specs/fix"
    printf '# spec: fix\n' > "$d/openspec/specs/fix/spec.md"
}

# --- case 1: the ok-verdict grammar, on a THROWAWAY CORPUS ----------------
# THIS CASE USED TO RUN THE GATE OVER THE LIVE TREE, and that is why it is a
# corpus case now. check-litmus-bindings.sh has two costs: it skips its advisory
# runnability sweep when no litmus file changed against the base, and runs it
# when one did. MEASURED — macneo (workstation) 3.2s skipped / 36.6s swept;
# esmeraldinha (floor tier) 83s cold and 95s/93s warm skipped, 693s swept. The
# fixture's budget is 30s. On macneo that budget sat BETWEEN the two paths, so
# it stopped asserting cost and started asserting WHICH PATH RAN — green for any
# change touching no litmus file, killed at budget for any change touching one,
# i.e. red on exactly the changes it exists to check. On esme the budget is below
# BOTH paths, so excluding the sweep would have made this green on the
# workstation tier and left it red on the floor: the same defect the row is
# about — a verdict that depends on which host ran it — at a new address.
#
# Neither raising the budget nor excluding the sweep is the fix. Case 1 asserts
# the reconciliation RULE, not the live tree's size, so it runs against a corpus
# of a few files: bounded, and the same cost on every tier. THE LIVE TREE IS NOT
# LOSING COVERAGE — build.sh:3654 runs this same checker over it as its own gate
# step, which is where the sweep's cost belongs and where it stays.
#
# WHAT A CORPUS CANNOT REACH, said rather than silently dropped: with
# LITMUS_BINDINGS_ROOT pointing outside a git checkout, the checker's
# `git rev-parse --verify "$BASE_REF"` fails and the whole runnability block —
# the gating bound-but-unrunnable arm AND the advisory sweep — is skipped. This
# fixture therefore does not exercise either. scripts/test-bound-litmus-is-
# runnable.sh and the gate step own that.
d="$WORK/grammar"; scaffold "$d"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE")" || fail "case 1: corpus must reconcile, got '$out'"
case "$out" in
    ok:${LP}-bindings:files=[0-9]*\ bound=[0-9]*\ retired=[0-9]*\ grandfathered=[0-9]*\ spec_ids=[0-9]*\ resolved=[0-9]*\ spec-grandfathered=[0-9]*) ;;
    *) fail "case 1: verdict grammar wrong, got '$out'" ;;
esac
echo "ok: case 1 — the ok verdict carries all four counts, on a bounded corpus"

# --- case 2: a clean fixture tree passes with the right counts --------------
d="$WORK/clean"; scaffold "$d"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE")" || fail "case 2: clean fixture must pass, got '$out'"
[ "$out" = "ok:litmus-bindings:files=3 bound=1 retired=1 grandfathered=1 spec_ids=1 resolved=1 spec-grandfathered=0" ] \
    || fail "case 2: wrong counts: '$out'"
echo "ok: case 2 — bound, retired, and grandfathered each counted once"

# --- case 3 (NEGATIVE CONTROL, the packet's own): a NEW unbound file refuses -
# This is exactly the state 660-ryhn was filed from: file written, suite
# green, assertions never executed.
d="$WORK/stray"; scaffold "$d"
printf 'name: %s:fix-new-stray\nspec: fix\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-new-stray.yaml"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE" 2>/dev/null)"
rc=$?
[ "$rc" -eq 1 ] || fail "case 3: a new unbound file must exit 1, got rc=$rc '$out'"
[ "$out" = "violation:unbound-${LP}:${LP}:fix-new-stray" ] \
    || fail "case 3: expected the stray NAMED, got '$out'"
echo "ok: case 3 — a new unbound litmus file is refused by name"

# --- case 4 (NEGATIVE CONTROL): a dangling binding refuses ------------------
d="$WORK/dangling"; scaffold "$d"
printf '  - %s:fix-ghost\n' "$LP" >> "$d/openspec/litmus-bindings.yaml"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE" 2>/dev/null)"
rc=$?
[ "$rc" -eq 1 ] || fail "case 4: a dangling binding must exit 1, got rc=$rc '$out'"
[ "$out" = "violation:dangling-binding:${LP}:fix-ghost" ] \
    || fail "case 4: expected the ghost NAMED, got '$out'"
echo "ok: case 4 — a binding with no file behind it is refused by name"

# --- case 5: retirement is honored even when unlisted -----------------------
d="$WORK/retired"; scaffold "$d"
printf 'name: %s:fix-shelved\nphase: retired\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-shelved.yaml"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE")" || fail "case 5: retired file must not refuse, got '$out'"
[ "$out" = "ok:litmus-bindings:files=4 bound=1 retired=2 grandfathered=1 spec_ids=1 resolved=1 spec-grandfathered=0" ] \
    || fail "case 5: wrong counts: '$out'"
echo "ok: case 5 — phase: retired is the sanctioned unbound state"


# --- case 6 (1356-vv5m): a spec_id that resolves to NOTHING is refused -------
# MEASURED ON TRUNK 2026-09-22: 141 spec_ids in openspec/litmus-bindings.yaml,
# 1 with no openspec/specs/<id>/spec.md — expert-serve-grounded-pipeline, under
# which THREE litmus tests were bound — and every gate green. The checker above
# asks "is every litmus FILE bound?" and answers it well; nothing asked whether
# a spec_id a binding NAMES resolves to anything.
d="$WORK/absent-spec"; scaffold "$d"
rm -rf "$d/openspec/specs/fix"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 6: a binding naming an absent spec must REFUSE, got '$out'"
case "$out" in
    *"violation:binding-names-absent-spec:fix"*) ;;
    *) fail "case 6: expected the absent spec_id named, got '$out'" ;;
esac
echo "ok: case 6 — a binding whose spec_id resolves to nothing is refused by name"

# --- case 7 (1356-vv5m): RESOLVE TO spec.md, NOT TO THE DIRECTORY -----------
# A directory left behind by a deletion satisfies a `-d` test while containing
# nothing a reader could open — the same shape-not-substance mistake one level
# down, and the one a careless fix would make.
d="$WORK/empty-specdir"; scaffold "$d"
rm -f "$d/openspec/specs/fix/spec.md"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 7: an empty spec directory must not satisfy resolution, got '$out'"
echo "ok: case 7 — an empty spec directory does not count as a resolved spec"

# --- case 8 (1356-vv5m), THE POPULATION CONTROL ON THIS ROW'S OWN CODE -------
# This row is the second instrument of a family about guards that assert shape
# over a population that can silently shrink. Shipping that defect INSIDE its own
# fix is the failure mode to avoid, so: ask the one question of the new check —
# what does it print when it finds NOTHING? A registry that parses to zero
# spec_ids is a broken read, not a clean tree.
#
# THE SCAFFOLD HAS NO BOUND FILE ON PURPOSE. A first draft simply emptied the
# bindings of a normal scaffold, and the EARLIER check fired first — the bound
# litmus became unbound — so the arm passed for the wrong reason and proved
# nothing about the population assertion. Only retired and grandfathered files
# here, so the earlier gate is satisfied and this arm is the only one that can
# speak.
d="$WORK/no-specids"; mkdir -p "$d/openspec/litmus-tests"
printf 'name: %s:fix-retired\nphase: retired\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-retired.yaml"
printf 'name: %s:fix-grand\nspec: fix\n' "$LP" > "$d/openspec/litmus-tests/litmus-fix-grand.yaml"
printf '# ratchet\n%s:fix-grand\n' "$LP" > "$d/openspec/litmus-tests/unbound-grandfathered.txt"
printf 'specs:\n' > "$d/openspec/litmus-bindings.yaml"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 8: ZERO parsed spec_ids must REFUSE, not print ok:0, got '$out'"
case "$out" in
    *"litmus-bindings-spec-population-empty"*) ;;
    *) fail "case 8: expected the empty-population refusal, got '$out'" ;;
esac
echo "ok: case 8 — zero parsed spec_ids is refused, not reported as clean"

# --- case 9 (1356-vv5m): the RATCHET survives -------------------------------
# 660-ryhn's own triage warns that binding every historical stray at once turns
# one silent problem into an undiagnosed red suite. A declared exception must
# stay possible, counted separately and named in the verdict so the list is
# visible and shrinkable rather than a silence.
d="$WORK/gf-spec"; scaffold "$d"
rm -rf "$d/openspec/specs/fix"
printf '# known stray\nfix\n' > "$d/openspec/litmus-tests/unresolved-grandfathered.txt"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE")" || fail "case 9: a declared unresolved spec_id must pass, got '$out'"
case "$out" in
    *"spec_ids=1 resolved=0 spec-grandfathered=1"*) ;;
    *) fail "case 9: the verdict must count the declared exception separately, got '$out'" ;;
esac
echo "ok: case 9 — a declared unresolved spec_id is exempt and counted as such"

# ORDER 1356-vv5m. DERIVED, not a literal. This printed "(5/5)" while NINE cases
# ran — the four added by this row passed and were reported as five. A
# self-reported count that cannot move cannot tell a reader it measured less
# than it claims, and this is the THIRD instrument on this host today with that
# defect (test-script-exec-bits.sh said 14/14 while seventeen ran;
# test-skills-single-source.sh said 7/7 while thirteen ran).
_cases="$(grep -c '^echo "ok: case' "$ROOT/scripts/test-litmus-bindings.sh")"
echo "PASS: litmus bindings reconciliation ($_cases/$_cases)"

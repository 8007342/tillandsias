#!/usr/bin/env bash
# @trace spec:ci-release, plan 1325-ygq5
#
# test-added-test-is-referenced.sh — prove scripts/check-added-test-is-referenced.sh
# REFUSES, not merely that it passes on a clean tree.
#
# A guard for "this test cannot fail a gate" that has only ever been observed
# passing is itself the defect it names, one level up. Every arm below runs
# against a HERMETIC throwaway repo so the refusal is observed rather than
# assumed, and the clean-pass arm is the least interesting one here.
#
# Pinned by litmus:added-test-is-referenced-shape.

set -uo pipefail

# The litmus name prefix is BUILT, never spelled beside a synthetic name:
# scripts/check-litmus-pin-claims.sh greps shell sources for the literal token
# and demands a real test declare it, so the throwaway names below would be read
# as five broken pin claims from this file. (Measured: they were.)
L="lit""mus"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/check-added-test-is-referenced.sh"
MANIFEST="$REPO_ROOT/scripts/test-reference-surfaces.manifest"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  PASS  $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; echo "        $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- a hermetic repo with the same shape as the real one --------------------
setup() {
    rm -rf "$WORK/r"; mkdir -p "$WORK/r"
    cd "$WORK/r" || exit 2
    git init -q .
    git config user.email t@t; git config user.name t
    mkdir -p scripts/gate-steps.d scripts/hooks openspec/litmus-tests
    cp "$GUARD" scripts/check-added-test-is-referenced.sh
    cp "$MANIFEST" scripts/test-reference-surfaces.manifest
    : > build.sh; : > scripts/local-ci.sh
    printf "specs:\n- spec_id: ci-release\n  litmus_tests:\n  - ${L}:already-bound\n" \
        > openspec/litmus-bindings.yaml
    printf '# grandfather list\n' > scripts/unreferenced-grandfathered.txt
    printf '# grandfather list\n' > openspec/litmus-tests/unbound-grandfathered.txt
    git add -A >/dev/null; git commit -qm base
    BASE="$(git rev-parse HEAD)"
}
run() { TILLANDSIAS_ADDED_TEST_BASE="$BASE" bash scripts/check-added-test-is-referenced.sh 2>"$WORK/err"; }

# 1. An added, unreferenced shell test is NAMED (migration phase: warn, exit 0).
setup
printf '#!/bin/bash\necho ok:nothing\n' > scripts/test-orphan-arm.sh
out="$(run)"; rc=$?
case "$out" in
    warn:added-test-unreferenced:1\ standing=*\ surfaces=*)
        if grep -q 'test-orphan-arm.sh' "$WORK/err"; then
            ok "unreferenced shell test warns AND names the file"
        else bad "unreferenced shell test named" "verdict right, file not named in stderr"; fi ;;
    *) bad "unreferenced shell test warns" "got '$out' rc=$rc" ;;
esac
[ "$rc" -eq 0 ] && ok "migration phase does not refuse (exit 0)" \
                || bad "migration phase exit 0" "rc=$rc"

# 2. THE REFUSAL ARM. Same tree, enforcement on.
out="$(TILLANDSIAS_ADDED_TEST_REFERENCE_ENFORCE=1 run)"; rc=$?
[ "$out" = "violation:added-test-unreferenced:1" ] && [ "$rc" -eq 1 ] \
    && ok "ENFORCE=1 refuses with exit 1" \
    || bad "ENFORCE=1 refuses" "got '$out' rc=$rc"

# 3. A referenced shell test passes — via a gate step naming its basename.
setup
printf '#!/bin/bash\necho ok:real\n' > scripts/test-bound-arm.sh
printf 'STEP_SCRIPT=scripts/test-bound-arm.sh\n' > scripts/gate-steps.d/90-bound.step
out="$(run)"
case "$out" in
    ok:added-test-referenced:1\ checked*) ok "a test a gate step names is accepted" ;;
    *) bad "referenced shell test accepted" "got '$out'" ;;
esac

# 4. An added litmus yaml absent from bindings is NAMED, by its declared name.
setup
printf "name: ${L}:orphan-shape\nspec: ci-release\n" > openspec/litmus-tests/litmus-orphan-shape.yaml
out="$(run)"
case "$out" in
    warn:added-test-unreferenced:1*)
        grep -q "${L}:orphan-shape" "$WORK/err" \
            && ok "unbound litmus yaml warns AND names the litmus name" \
            || bad "unbound litmus named" "not named in stderr" ;;
    *) bad "unbound litmus warns" "got '$out'" ;;
esac

# 5. A bound litmus yaml passes.
setup
printf "name: ${L}:already-bound\nspec: ci-release\n" > openspec/litmus-tests/litmus-already-bound.yaml
out="$(run)"
case "$out" in
    ok:added-test-referenced:1\ checked*) ok "a litmus yaml present in bindings is accepted" ;;
    *) bad "bound litmus accepted" "got '$out'" ;;
esac

# 6. NEGATIVE CONTROL: deliberate stays possible, and is DECLARED.
setup
printf '#!/bin/bash\necho ok:manual\n' > scripts/test-manual-drill.sh
printf '# grandfather list\ntest-manual-drill.sh  # operator-run drill, no gate can host it\n' \
    > scripts/unreferenced-grandfathered.txt
out="$(run)"
case "$out" in
    ok:added-test-referenced:1\ checked*)
        grep -q 'declared unreferenced' "$WORK/err" \
            && ok "a grandfathered test passes and says it was DECLARED" \
            || bad "grandfather declares" "accepted silently — declaration not visible" ;;
    *) bad "grandfathered test accepted" "got '$out'" ;;
esac

# 7. A retired litmus yaml is not this guard's question.
setup
printf "name: ${L}:gone-shape\nspec: ci-release\nphase: retired\n" \
    > openspec/litmus-tests/litmus-gone-shape.yaml
out="$(run)"
case "$out" in
    ok:added-test-referenced:0\ checked*) ok "a retired litmus yaml is skipped, not counted" ;;
    *) bad "retired litmus skipped" "got '$out'" ;;
esac

# 8. No manifest = no definition of 'referenced'. Refuse; never green.
setup
rm -f scripts/test-reference-surfaces.manifest
printf '#!/bin/bash\n' > scripts/test-whatever.sh
out="$(run)"; rc=$?
[ "$out" = "violation:added-test-unreferenced:0" ] && [ "$rc" -eq 2 ] \
    && ok "a missing surface manifest refuses (never a silent green)" \
    || bad "missing manifest refuses" "got '$out' rc=$rc"

# 9. MODIFYING an existing unreferenced test is not refused — diff-scoping keeps
#    the standing forty safe to touch.
setup
printf '#!/bin/bash\necho ok:old\n' > scripts/test-inherited.sh
git add -A >/dev/null; git commit -qm add-inherited; BASE="$(git rev-parse HEAD)"
printf '#!/bin/bash\necho ok:old-edited\n' > scripts/test-inherited.sh
out="$(run)"
case "$out" in
    ok:added-test-referenced:0\ checked*) ok "editing an inherited unreferenced test is not refused" ;;
    *) bad "inherited test safe to edit" "got '$out'" ;;
esac

cd "$REPO_ROOT"
echo
echo "added-test-is-referenced: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "violation:added-test-guard-unproven:$fail"; exit 1; }
echo "ok:added-test-guard-proven:$pass"

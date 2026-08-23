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
}

# --- case 1: the live tree passes ------------------------------------------
out="$(bash "$GATE")" || fail "case 1: live tree must pass, got '$out'"
case "$out" in
    ok:litmus-bindings:files=*) ;;
    *) fail "case 1: unexpected verdict '$out'" ;;
esac
echo "ok: case 1 — live tree reconciles ($out)"

# --- case 2: a clean fixture tree passes with the right counts --------------
d="$WORK/clean"; scaffold "$d"
out="$(LITMUS_BINDINGS_ROOT="$d" bash "$GATE")" || fail "case 2: clean fixture must pass, got '$out'"
[ "$out" = "ok:litmus-bindings:files=3 bound=1 retired=1 grandfathered=1" ] \
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
[ "$out" = "ok:litmus-bindings:files=4 bound=1 retired=2 grandfathered=1" ] \
    || fail "case 5: wrong counts: '$out'"
echo "ok: case 5 — phase: retired is the sanctioned unbound state"

echo "PASS: litmus bindings reconciliation (5/5)"

#!/usr/bin/env bash
# @trace spec:ci-release, plan 1334-57at (cites 1333-jpq5, 1329-m8dk)
#
# test-census-enforced-reachability-split.sh — does the enforcement census
# distinguish an assertion that CAN run from one that cannot?
#
# THE DEFECT THIS PINS. Measured on esmeraldinha at 3048e72dc: 53 of the 244
# steps the census called ENFORCED live in 16 litmus files nothing runs — 21.7%
# of the enforced population, inert by construction. A grandfathered-unbound or
# retired file is never executed by any suite, so an assert added to it is, in
# 1333-jpq5's own words, "correct and inert". The census printed ONE ENFORCED
# line, so a closure expressed as an enforced count overstated real enforcement
# by about a fifth, and 1329-m8dk's closure inherited that.
#
# NOT AN ACCUSATION AND THE FIXTURE SHOULD NOT BE READ AS ONE. Most of those
# assertions are historical strays that predate the census counting them. The
# claim is only that the census should say which of the two it is.
#
# REACHABLE means bound in litmus-bindings.yaml AND not `phase: retired`, the
# same definition census-litmus-reachability.sh uses. Everything else is INERT.
#
# HERMETIC: every arm builds its own tree under a temp dir and copies the census
# in, so REPO_ROOT resolves to the throwaway and the real corpus is never read.
# The arms assert on counts the fixture itself planted, never on today's totals,
# which move.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CENSUS="$REPO_ROOT/scripts/census-litmus-step-enforcement.sh"
[ -f "$CENSUS" ] || { echo "blocked:fixture:census-script-absent:$CENSUS"; exit 2; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# A litmus file with exactly ONE step, which carries an assert (so: ENFORCED).
write_litmus() { # <path> <name> [retired]
    { printf 'name: %s\n' "$2"
      printf 'spec: fixture-spec\n'
      [ "${3:-}" = "retired" ] && printf 'phase: retired\n' || printf 'phase: pre-build\n'
      printf 'size: instant\n\ncritical_path:\n'
      printf '  - step: "the only step"\n'
      printf '    command: "echo ok:fixture"\n'
      printf '    expected_behavior: "ok:fixture"\n'
      printf '    assert_exit: 0\n'
    } > "$1"
}

build_tree() { # <dir> <bind-the-stray?>
    local d="$1" bind="$2"
    mkdir -p "$d/scripts" "$d/openspec/litmus-tests"
    cp "$CENSUS" "$d/scripts/"
    write_litmus "$d/openspec/litmus-tests/litmus-bound-one.yaml"   "litmus:bound-one"
    write_litmus "$d/openspec/litmus-tests/litmus-stray-one.yaml"   "litmus:stray-one"
    write_litmus "$d/openspec/litmus-tests/litmus-retired-one.yaml" "litmus:retired-one" retired
    { printf "version: '1.0'\nspecs:\n- spec_id: fixture-spec\n  status: active\n  litmus_tests:\n"
      printf '  - litmus:bound-one\n'
      printf '  - litmus:retired-one\n'
      [ "$bind" = "bind-stray" ] && printf '  - litmus:stray-one\n'
    } > "$d/openspec/litmus-bindings.yaml"
    printf 'litmus:stray-one\n' > "$d/openspec/litmus-tests/unbound-grandfathered.txt"
}

field() { # <output> <label>  -> the integer on that line
    printf '%s\n' "$1" | sed -n "s/.*${2}[^0-9-]*\([0-9][0-9]*\).*/\1/p" | head -1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── ARM 1: the census reports the split at all ───────────────────────────────
# PRE-FIX THIS ARM IS THE ONE THAT REDS: today's census prints a single
# "ENFORCED" line and no reachability at all.
build_tree "$TMP/a" no-bind
out_a="$(bash "$TMP/a/scripts/census-litmus-step-enforcement.sh" 2>&1)"
if printf '%s\n' "$out_a" | grep -q 'ENFORCED-REACHABLE' \
   && printf '%s\n' "$out_a" | grep -q 'ENFORCED-INERT'; then
    ok "ARM 1: the census reports ENFORCED-REACHABLE and ENFORCED-INERT"
else
    bad "ARM 1: no reachability split in the census output" \
        "got: $(printf '%s\n' "$out_a" | grep -i enforced | tr '\n' '|')"
fi

# ── ARM 2: a bound file's enforced step is REACHABLE ─────────────────────────
r_a="$(field "$out_a" 'ENFORCED-REACHABLE')"
if [ "${r_a:-}" = "1" ]; then
    ok "ARM 2: the bound file's enforced step counts REACHABLE (1)"
else
    bad "ARM 2: expected ENFORCED-REACHABLE=1, got '${r_a:-<no such line>}'"
fi

# ── ARM 3: grandfathered-unbound AND retired are INERT (2 of them) ───────────
i_a="$(field "$out_a" 'ENFORCED-INERT')"
if [ "${i_a:-}" = "2" ]; then
    ok "ARM 3: the unbound stray and the retired file count INERT (2)"
else
    bad "ARM 3: expected ENFORCED-INERT=2, got '${i_a:-<no such line>}'"
fi

# ── ARM 4: MUTATION. Binding the stray must move it across the line ──────────
# Identical bytes in the step; the ONLY change is a name added to the bindings.
# If this arm does not move, the membership test is decorative.
build_tree "$TMP/b" bind-stray
out_b="$(bash "$TMP/b/scripts/census-litmus-step-enforcement.sh" 2>&1)"
r_b="$(field "$out_b" 'ENFORCED-REACHABLE')"
i_b="$(field "$out_b" 'ENFORCED-INERT')"
if [ "${r_b:-}" = "2" ] && [ "${i_b:-}" = "1" ]; then
    ok "ARM 4: binding the stray moves it INERT->REACHABLE (2/1)"
else
    bad "ARM 4: expected 2 reachable / 1 inert after binding the stray" \
        "got reachable='${r_b:-none}' inert='${i_b:-none}'"
fi

# ── ARM 5: the two halves must sum to the single ENFORCED total ──────────────
# A split that does not reconcile is how a third bucket hides.
e_a="$(printf '%s\n' "$out_a" | sed -n 's/^ *ENFORCED  *(assert.*[^0-9]\([0-9][0-9]*\) *$/\1/p' | head -1)"
if [ -n "${e_a:-}" ] && [ -n "${r_a:-}" ] && [ -n "${i_a:-}" ] \
   && [ "$((r_a + i_a))" = "$e_a" ]; then
    ok "ARM 5: REACHABLE + INERT == ENFORCED ($r_a + $i_a == $e_a)"
else
    bad "ARM 5: the split does not reconcile with ENFORCED" \
        "enforced='${e_a:-none}' reachable='${r_a:-none}' inert='${i_a:-none}'"
fi

# ── ARM 6: the closure figure must name the REACHABLE count ──────────────────
if printf '%s\n' "$out_a" | grep -qiE 'CLOSURE FIGURE.*reachable|reachable.*CLOSURE FIGURE'; then
    ok "ARM 6: the closure figure names reachability"
else
    bad "ARM 6: the closure figure does not name reachability" \
        "got: $(printf '%s\n' "$out_a" | grep -i closure | tr '\n' '|')"
fi

# ── ARM 7: the REAL corpus reconciles too ───────────────────────────────────
# The hermetic arms prove the RULE. This proves the rule is wired to the census
# a reader will actually run. It asserts only that the halves sum and that
# something is enforced — never a today-number, because those move.
out_r="$(bash "$CENSUS" 2>&1)"
e_r="$(printf '%s\n' "$out_r" | sed -n 's/^  ENFORCED   .*[^0-9]\([0-9][0-9]*\) *$/\1/p' | head -1)"
rr="$(field "$out_r" 'ENFORCED-REACHABLE')"
ir="$(field "$out_r" 'ENFORCED-INERT')"
if [ -n "${e_r:-}" ] && [ -n "${rr:-}" ] && [ -n "${ir:-}" ] \
   && [ "$e_r" -gt 0 ] && [ "$((rr + ir))" = "$e_r" ]; then
    ok "ARM 7: the real corpus reconciles ($rr + $ir == $e_r)"
else
    bad "ARM 7: the real corpus does not reconcile" \
        "enforced='${e_r:-none}' reachable='${rr:-none}' inert='${ir:-none}'"
fi

printf 'census-enforced-reachability-split: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0

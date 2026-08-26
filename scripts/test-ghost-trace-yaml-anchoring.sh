#!/usr/bin/env bash
# @trace spec:spec-traceability
#
# Fixture for order 867-vd4z: the ghost-trace gate scans YAML, and it
# distinguishes an ANNOTATION from PROSE THAT DISCUSSES ONE.
#
# Why a behavioural fixture and not a grep for the pattern in trace-coverage.sh:
# a text pin breaks on any correct refactor and passes any behavioural
# regression that keeps the string. Its sibling resolvers
# (test-resolve-open-pr.sh, test-resolve-release-run.sh) are the model.
#
# Every scenario writes ONE temporary YAML inside the repo — the scan is
# repo-relative, so it has to be reachable — and removes it on every exit path
# via trap. The file name is unique per process, so a concurrent cycle's scan
# cannot collide with it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FIXTURE="openspec/litmus-tests/zz-ghost-anchor-fixture-$$.yaml"
cleanup() { rm -f "$ROOT/$FIXTURE"; }
trap cleanup EXIT INT TERM

# THE MARKER IS ASSEMBLED AT RUNTIME AND NEVER WRITTEN LITERALLY IN THIS FILE.
# `.sh` is inside the scan's own include list, so a literal marker in these
# printf strings would register as four real ghost traces and turn the gate red
# — the fixture would fail the thing it exists to test. The first draft did
# exactly that, which is the same trap the comment in trace-coverage.sh records
# for its own prose. Splitting the token keeps the grep from matching the file.
AT="@""trace"

pass=0
fail=0
_result() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 — expected exit $2, got $3" >&2
    fi
}

_gate_exit() {
    scripts/trace-coverage.sh --gate >/dev/null 2>&1
    echo $?
}

# Guard: the tree must be clean for the gate BEFORE we perturb it, or every
# result below is measuring someone else's ghost rather than the fixture's.
baseline_exit="$(_gate_exit)"
if [[ "$baseline_exit" != "0" ]]; then
    echo "SKIP: ghost-trace gate is already failing on this tree (exit $baseline_exit) — the fixture cannot attribute its own result" >&2
    exit 0
fi

# 1. An anchored comment annotation naming a nonexistent spec is a NEW ghost.
printf '# %s spec:zzz-no-such-spec-anchored-comment\n' "$AT" > "$FIXTURE"
_result "anchored comment annotation is caught" 1 "$(_gate_exit)"

# 2. An anchored quoted evidence item is the OTHER real annotation shape.
printf 'observability:\n  traces:\n    - "%s spec:zzz-no-such-spec-quoted-item"\n' "$AT" > "$FIXTURE"
_result "anchored quoted evidence item is caught" 1 "$(_gate_exit)"

# 3. PROSE mentioning an annotation mid-line is NOT an annotation. This is the
#    scenario the whole anchoring rule exists for: without it the scan reports
#    ids like "chromium-" harvested out of a brace shorthand, and documentation
#    that merely discusses traces fails the build.
printf '# some note that mentions %s spec:zzz-prose-mention-not-real inline\n' "$AT" > "$FIXTURE"
_result "unanchored prose mention is ignored" 0 "$(_gate_exit)"

# 4. A description block scalar is prose too, even indented under a key.
printf 'description: |\n  See the note about %s spec:zzz-block-scalar-not-real for detail.\n' "$AT" > "$FIXTURE"
_result "block-scalar prose is ignored" 0 "$(_gate_exit)"

# 5. NEGATIVE CONTROL. Removing the fixture must restore a green gate — without
#    this, scenarios 3 and 4 could be passing because the gate is broken open.
cleanup
_result "clean tree restores a green gate" 0 "$(_gate_exit)"

total=$((pass + fail))
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: ghost-trace yaml anchoring fixture $pass/$total scenarios green (anchored-comment, anchored-quoted-item, prose-mention-ignored, block-scalar-ignored, clean-tree-restores-green)"
    exit 0
fi
echo "FAIL: ghost-trace yaml anchoring fixture $pass/$total green, $fail failed" >&2
exit 1

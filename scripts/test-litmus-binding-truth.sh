#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-litmus-binding-truth.sh — ORDER 1304-wbb2.
#
# WHAT THIS PINS. Nothing compared a litmus file's own `spec:` field with the
# block it is listed under in openspec/litmus-bindings.yaml, so a misbound
# litmus RUNS and is MISATTRIBUTED — the spec it declares reads covered while
# holding zero tests, and the block it was filed under takes credit for a test
# that names a different owner. Measured on the live corpus 2026-09-20: 69 such
# bindings across 42 files, including two Windows tests filed under macOS and
# one macOS test under Windows.
#
# TWO CRITERIA, SEPARATE, BECAUSE A FIX FOR ONE CAN LEAVE THE OTHER:
#   2a MISATTRIBUTION — bound under a block that is not among the file's specs.
#   2b INVISIBILITY   — bound under no block at all. Already guarded by
#                       660-ryhn; arms 3-4 pin that it STAYS guarded, since
#                       this change edits the same script.
# Each has a MUTATION arm, because a guard added without one is this family's
# own defect committed while fixing it.
#
# THE FIXTURE BUILDS A REAL GIT REPO, and that is not ceremony. The checks
# under test are DIFF-SCOPED: they compare against a base ref and gate only
# bindings ADDED in the change. A plain directory tree has no base ref, the
# whole diff-scoped block is skipped, and the fixture would report green while
# exercising nothing — the precise failure this row is about. So each arm
# commits a base, then adds the binding, then runs the checker against that
# base.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:litmus-binding-truth:[0-9]+/4|violation:litmus-binding-truth:[0-9]+/4|skip:no-git)$
# Exit 0 on the ok and on the skip; 1 on a violation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-litmus-bindings.sh"

command -v git >/dev/null 2>&1 || { echo "skip:no-git"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/binding-truth.XXXXXX")"
MUTANT=""
cleanup() { rm -rf "$W"; [ -n "$MUTANT" ] && rm -f "$MUTANT"; }
trap cleanup EXIT

# check-litmus-pin-claims.sh (721-77yu) scans scripts/ for `<prefix>:<name>`
# and reads a bare occurrence as a claim that a litmus of that name verifies
# this script. The fixture's probe is TEST DATA, not a pin — but a guard cannot
# tell a mention from a use, so the token is ASSEMBLED rather than written.
#
# Unlike scripts/test-litmus-parse-instruments-agree.sh, which simply dropped
# the prefix from its corpus files, here the prefix is LOAD-BEARING: the
# checker under test greps `litmus:[a-z0-9._-]+` out of the bindings registry,
# so the probe must carry a real one to be found at all. Same precedent and
# same reasoning as scripts/test-litmus-parse-only-duplicate-key.sh.
LIT="litmus"

pass=0
fail() { echo "FAIL: $*" >&2; }

# build_tree <dir> <declared-spec-line> — a corpus of exactly one litmus file,
# and a bindings registry with two blocks and no binding for it yet.
build_tree() {
    local d="$1" declared="$2"
    mkdir -p "$d/openspec/litmus-tests"
    cat > "$d/openspec/litmus-tests/litmus-truth-probe.yaml" <<YAML
name: ${LIT}:truth-probe
spec: $declared
phase: pre-build
severity: low
size: instant
description: >
  probe for 1304-wbb2
critical_path:
  - step: "a step"
    command: "echo hello"
    expected_behavior: "hello"
    timeout_ms: 1000
YAML
    cat > "$d/openspec/litmus-bindings.yaml" <<'YAML'
version: '1.0'
description: fixture registry
specs:
- spec_id: intended-spec
  status: active
  litmus_tests: []
  coverage_ratio: 0
  last_verified: '2026-09-20'
- spec_id: wrong-spec
  status: active
  litmus_tests: []
  coverage_ratio: 0
  last_verified: '2026-09-20'
YAML
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email fixture@local 2>/dev/null
    git -C "$d" config user.name fixture 2>/dev/null
    git -C "$d" add -A 2>/dev/null
    git -C "$d" commit -qm base 2>/dev/null
}

# bind_under <dir> <block> — append the binding to one block, as a change.
bind_under() {
    local d="$1" blk="$2"
    awk -v want="$blk" -v pfx="$LIT" '
        /^- spec_id: / { cur = $3 }
        /^  litmus_tests: \[\]$/ && cur == want { print "  litmus_tests:"; print "  - " pfx ":truth-probe"; next }
        { print }
    ' "$d/openspec/litmus-bindings.yaml" > "$d/.b" && mv "$d/.b" "$d/openspec/litmus-bindings.yaml"
}

run_checker() { # dir, checker-path -> prints verdict, sets RC
    local d="$1" c="$2"
    LITMUS_BINDINGS_ROOT="$d" TILLANDSIAS_LITMUS_BIND_BASE=HEAD \
        bash "$c" 2>/dev/null | tail -1
}

# ---------------------------------------------------------------- ARM 1 (2a)
# Declared intended-spec, bound under wrong-spec -> must REFUSE, naming both.
A="$W/a1"; build_tree "$A" "intended-spec"; bind_under "$A" "wrong-spec"
out="$(run_checker "$A" "$CHECKER")"
if printf '%s' "$out" | grep -q '^violation:binding-spec-mismatch:' \
   && printf '%s' "$out" | grep -q 'declared=intended-spec' \
   && printf '%s' "$out" | grep -q 'bound-under=wrong-spec'; then
    pass=$((pass + 1))
else
    fail "arm 1 (2a): a misbound litmus was not refused with both ids -- got: $out"
fi

# ---------------------------------------------------------------- ARM 2 (2a mutation)
# Remove the cross-check; arm 1's tree must then be ACCEPTED.
# NEUTRALISE THE GUARD, NOT ITS MESSAGE — same correction as arm 4. Replacing
# the `echo` leaves the enclosing `if [ -n "$misbound" ]; then … exit 1; fi`
# intact, so the mutant still refuses. v1 of this arm did that and PASSED
# ANYWAY, because the cross-check was then gated behind the runner's presence
# and never ran in this fixture at all: a false pass sitting on top of a
# skipped check, which is the pair of defects this row exists for.
MUTANT="$ROOT/scripts/.binding-truth-mutant.$$.sh"
sed 's|^ *if \[ -n "\$misbound" \]; then|    if false; then # MUTATED-NO-CROSSCHECK|' \
    "$CHECKER" > "$MUTANT"
if ! grep -q 'MUTATED-NO-CROSSCHECK' "$MUTANT"; then
    fail "arm 2: the mutation did not apply; the refusal line has been reworded"
elif ! bash -n "$MUTANT" 2>/dev/null; then
    fail "arm 2: the mutant does not parse"
else
    out="$(run_checker "$A" "$MUTANT")"
    if printf '%s' "$out" | grep -q '^ok:litmus-bindings:'; then
        pass=$((pass + 1))
    else
        fail "arm 2: removing the cross-check did NOT restore acceptance -- arm 1 may pass for another reason -- got: $out"
    fi
fi
rm -f "$MUTANT"; MUTANT=""

# ---------------------------------------------------------------- ARM 3 (2b)
# Bound under NO block -> must REFUSE as unbound (660-ryhn, must stay true).
B="$W/a3"; build_tree "$B" "intended-spec"
out="$(run_checker "$B" "$CHECKER")"
if printf '%s' "$out" | grep -q '^violation:unbound-litmus:' \
   && printf '%s' "$out" | grep -q 'truth-probe'; then
    pass=$((pass + 1))
else
    fail "arm 3 (2b): an unbound litmus was not refused -- got: $out"
fi

# ---------------------------------------------------------------- ARM 4 (2b mutation)
# NEUTRALISE THE GUARD, NOT ITS MESSAGE. v1 of this arm replaced the `echo
# "violation:unbound-litmus:…"` line, which sits INSIDE `if [ -n "$unbound" ];
# then … exit 1; fi` — so the mutant still exited 1 with an empty stdout and
# the arm failed for the wrong reason. Mutate the CONDITION.
MUTANT="$ROOT/scripts/.binding-truth-mutant.$$.sh"
sed 's|^if \[ -n "\$unbound" \]; then|if false; then # MUTATED-NO-UNBOUND|' \
    "$CHECKER" > "$MUTANT"
if ! grep -q 'MUTATED-NO-UNBOUND' "$MUTANT"; then
    fail "arm 4: the mutation did not apply; the unbound refusal has been reworded"
elif ! bash -n "$MUTANT" 2>/dev/null; then
    fail "arm 4: the mutant does not parse"
else
    out="$(run_checker "$B" "$MUTANT")"
    if printf '%s' "$out" | grep -q '^ok:litmus-bindings:'; then
        pass=$((pass + 1))
    else
        fail "arm 4: removing the unbound check did NOT restore acceptance -- got: $out"
    fi
fi
rm -f "$MUTANT"; MUTANT=""

if [ "$pass" -eq 4 ]; then
    echo "ok:litmus-binding-truth:4/4"
    exit 0
fi
echo "violation:litmus-binding-truth:$pass/4"
exit 1

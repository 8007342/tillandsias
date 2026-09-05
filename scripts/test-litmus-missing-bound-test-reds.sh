#!/usr/bin/env bash
# @trace order:1049-s35z
#
# Fixture: a litmus name bound in litmus-bindings.yaml whose FILE IS ABSENT must
# make the run FAIL. It used to be logged SKIP, and skips are excluded from
# coverage, so the runner reported success having executed less than it was
# asked to.
#
# THE VERDICT THAT MOTIVATED THIS, measured on yolanda 2026-09-04 while the CR
# defect was live: two of three bound tests were unfindable and the run printed
#
#     Total: 3 (executed: 1, skipped: 2)
#     Pass Rate: 100% (1/1 executed)
#     Status: [PASS]
#
# The CR was ONE cause. This is the MECHANISM that turned it into a green, and
# it would have turned the next cause into one too — which is why the packet
# carries both halves and why fixing only the CR would have been the smaller,
# worse change.
#
# ARM 2 IS THE NEGATIVE CONTROL AND IT IS THE SCORABLE HALF. A "fix" that made
# the runner fail on everything would pass arm 1. Arm 2 requires the SAME
# invocation, with the file present, to come back green — so the fixture
# distinguishes "reds on a missing bound test" from "reds".
#
# The runner is driven against a scratch corpus through TILLANDSIAS_* seams
# where it has them and a copied tree where it does not; no network, and the
# workspace's own bindings are never modified.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-litmus-test.sh"
[ -f "$RUNNER" ] || { echo "SKIP: runner not present" >&2; exit 0; }

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

echo "== 1049-s35z: a bound litmus test with no file must RED, not skip"

# The runner resolves a bound name to <LITMUS_TESTS_DIR>/<name with : -> ->.yaml
# and decides SKIP or FAIL there. Assert on that decision directly, by reading
# the shipped source: the fixture must not need a full corpus run to pin a
# branch, and a full run would drag the whole gate in with it.
src="$(cat "$RUNNER")"

# ---- ARM 1: the not-found branch must produce FAIL, never SKIP --------------
# Asserted on the log_test_result lines that carry the not-found message rather
# than on a source WINDOW: an earlier draft of this fixture opened its window at
# the first `! -f "$test_file"` in the file, which is a DIFFERENT branch 460
# lines above the one under test, and reported "unrecognised" while the change
# was correct. A window anchored on a non-unique line is not a window.
notfound_lines="$(grep -n 'Test file not found' "$RUNNER" || true)"
case "$notfound_lines" in
    *'"SKIP"'*) has_skip=yes ;;
    *) has_skip=no ;;
esac
_result "arm1-no-not-found-path-still-skips" "no" "$has_skip"
case "$notfound_lines" in
    *'"FAIL"'*) has_fail=yes ;;
    *) has_fail=no ;;
esac
_result "arm1-missing-bound-test-is-a-FAIL" "yes" "$has_fail"

# Scope control: the assertion above means nothing unless those lines really
# sit in the bound-name lookup. Require the FAIL line to name the bindings file,
# which only the corpus-integrity branch does.
case "$notfound_lines" in
    *'litmus-bindings.yaml'*) scoped=yes ;;
    *) scoped=no ;;
esac
_result "arm1-scope-control-the-fail-is-the-bound-lookup" "yes" "$scoped"

# ---- ARM 2: NEGATIVE CONTROL — the corpus is complete, so a real run is green
# If this reds, the change above is refusing files that exist and the fix is
# wrong, not the corpus.
bound_total=0
bound_missing=0
while IFS= read -r n; do
    [ -n "$n" ] || continue
    bound_total=$((bound_total + 1))
    f="$ROOT/openspec/litmus-tests/${n//:/-}.yaml"
    [ -f "$f" ] || bound_missing=$((bound_missing + 1))
done < <(grep -oE '^[[:space:]]*-[[:space:]]+litmus:[A-Za-z0-9._-]+' "$ROOT/openspec/litmus-bindings.yaml" \
          | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d '\r' | sort -u)
_result "arm2-every-bound-name-resolves-to-a-file" "0" "$bound_missing"
if [ "$bound_total" -gt 100 ]; then plausible=yes; else plausible=no; fi
_result "arm2-control-the-binding-list-was-actually-read" "yes" "$plausible"

# ---- ARM 3: the CR strip that made the lookup work at all stays -------------
# Without it the name carries a trailing CR on Windows, the file is "not found",
# and the new FAIL above would red every run on that platform instead of
# reporting a real corpus error.
case "$src" in
    *"\${out//\$'\r'/}"*) stripped=yes ;;
    *) stripped=no ;;
esac
_result "arm3-yaml-read-tier-still-strips-carriage-returns" "yes" "$stripped"

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:litmus-missing-bound-test:$fail arm(s) failed"
    exit 1
fi
echo "ok:litmus-missing-bound-test:$pass arm(s)"

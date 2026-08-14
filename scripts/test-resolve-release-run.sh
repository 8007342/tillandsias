#!/usr/bin/env bash
# @trace order:601-462g, spec:ci-release
set -uo pipefail

# Fixture for the release-run resolver (order 601-462g).
#
# The breach shape, reproduced with a fake gh: a workflow that never started
# makes `gh run list` print nothing and exit 0, so the runbook's command
# substitution succeeded with an empty run_id and walked into `gh run watch ""`.
# Absent and healthy shared an exit code.
#
# Hermetic: every scenario injects a stub gh through $GH. Nothing here touches
# GitHub, and nothing needs auth.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/scripts/resolve-release-run.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/release-run-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# stub_gh <stdout-text> <exit-code>
stub_gh() {
    printf '#!/usr/bin/env bash\nprintf "%%s" %q\nexit %s\n' "$1" "$2" > "$work/gh"
    chmod +x "$work/gh"
}

failures=()

# run <name> <expect-exit> <want-verdict>
run() {
    local name="$1" want_rc="$2" want="$3" rc=0 out
    out="$(GH="$work/gh" "$RESOLVER" v0.4.260813.1 2>&1)" || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        failures+=("$name: exit=$rc expected=$want_rc (out: $out)")
    elif [ "$out" != "$want" ]; then
        failures+=("$name: expected '$want', got '$out'")
    fi
}

# 1. THE BREACH: no run exists. gh prints nothing and exits 0 — which the old
#    runbook read as success.
stub_gh "" 0
run "no-run-empty-output" 1 "blocked:release-run:no-run-for-tag:v0.4.260813.1"

# 2. The same absence in its OTHER shape: `--jq '.[0].databaseId'` on an empty
#    array prints the literal "null". A bare emptiness test would pass this
#    through and hand `gh run watch null` a plausible-looking argument.
stub_gh "null" 0
run "no-run-null-output" 1 "blocked:release-run:no-run-for-tag:v0.4.260813.1"

# 3. gh FAILING is a different fact from gh having nothing to say. Collapsing
#    them would be a smaller copy of the bug this script fixes.
stub_gh "" 1
run "gh-failed" 1 "blocked:release-run:gh-failed:v0.4.260813.1"

# 4. POSITIVE CONTROL: a real run id resolves. Every case above asserts a
#    refusal, and a resolver that refused everything would satisfy all of them
#    while making the release unwatchable.
stub_gh "17482930571" 0
run "run-resolves" 0 "ok:release-run:17482930571"

# 5. Whitespace around a real id (gh emits a trailing newline) must not defeat
#    the resolution — a false refusal here would block every release.
stub_gh "17482930571
" 0
run "trailing-newline-tolerated" 0 "ok:release-run:17482930571"

# 6. A missing tag argument is named, not silently treated as "no run".
rc=0
out="$(GH="$work/gh" "$RESOLVER" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] || [ "$out" != "blocked:release-run:no-tag-given" ]; then
    failures+=("no-tag-given: exit=$rc out='$out'")
fi

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "release-run-resolver: FAIL ${#failures[@]} scenario(s)"
    exit 1
fi
echo "PASS: release-run-resolver fixture 6/6 scenarios green (no-run-empty-output, no-run-null-output, gh-failed, run-resolves, trailing-newline-tolerated, no-tag-given)"

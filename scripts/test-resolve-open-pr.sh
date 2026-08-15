#!/usr/bin/env bash
# @trace order:601-462g, spec:ci-release
set -uo pipefail

# Fixture for the open-PR resolver (order 601-462g).
#
# The breach shape, reproduced with a fake gh: with NO open PR,
# `gh pr list --json number --jq '.[0].number'` prints the literal `null` and
# exits 0. The runbook's `[[ -z "$existing_pr" ]]` test was therefore FALSE, so
# `gh pr create` never ran and the skill announced `PR #null` before walking
# into the merge step. Absent did not merely share an exit code with healthy —
# it produced a plausible-looking value.
#
# Hermetic: every scenario injects a stub gh through $GH. Nothing here touches
# GitHub, and nothing needs auth.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/scripts/resolve-open-pr.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/open-pr-fixture.XXXXXX")"
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
    out="$(GH="$work/gh" "$RESOLVER" main linux-next 2>&1)" || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        failures+=("$name: exit=$rc expected=$want_rc (out: $out)")
    elif [ "$out" != "$want" ]; then
        failures+=("$name: expected '$want', got '$out'")
    fi
}

# 1. THE BREACH: no open PR, and jq renders that absence as the literal "null".
#    The old emptiness test let this through as a PR number.
stub_gh "null" 0
run "no-pr-null-output" 1 "blocked:open-pr:none-open:linux-next->main"

# 2. The same absence in its other shape — an empty result set that prints
#    nothing at all — must refuse identically.
stub_gh "" 0
run "no-pr-empty-output" 1 "blocked:open-pr:none-open:linux-next->main"

# 3. gh FAILING (network, auth) is a different fact from gh having nothing to
#    say, and the caller needs to tell them apart: one is retryable, the other
#    means create the PR.
stub_gh "" 1
run "gh-failed" 1 "blocked:open-pr:gh-failed:linux-next->main"

# 4. POSITIVE CONTROL: a real PR number resolves. Every case above asserts a
#    refusal, and a resolver that refused everything would satisfy all of them
#    while making every release unmergeable.
stub_gh "81" 0
run "pr-resolves" 0 "ok:open-pr:81"

# 5. Whitespace around a real number (gh emits a trailing newline) must not
#    defeat resolution — a false refusal here opens a duplicate PR.
stub_gh "81
" 0
run "trailing-newline-tolerated" 0 "ok:open-pr:81"

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "open-pr-resolver: FAIL ${#failures[@]} scenario(s)"
    exit 1
fi
echo "PASS: open-pr-resolver fixture 5/5 scenarios green (no-pr-null-output, no-pr-empty-output, gh-failed, pr-resolves, trailing-newline-tolerated)"

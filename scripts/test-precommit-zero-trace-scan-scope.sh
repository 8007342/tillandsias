#!/usr/bin/env bash
# @trace order:734-sjb3
#
# Pin: excluding build output from the pre-commit spec sweep must not change the
# ANSWER, only the cost.
#
# WHY. `grep -r` with --include still WALKS every directory; --include only
# decides which files it opens. The sweep was descending the whole build output
# — 141,414 entries under target/ on yoga against 12,352 everywhere else — to
# read 928 source files. Measured here, GNU grep, five runs: the phase went from
# a 237ms median to 93ms. On macOS the same traversal is what 734-sjb3 twice
# identified as the dominant cost ("almost entirely SYSCALL time — process spawn
# plus filesystem traversal"), and macbookair measured this phase at 10373ms
# against its own 2500ms budget.
#
# THE RISK THE EXCLUSION CARRIES, and the only reason this fixture exists: a
# spec referenced ONLY from build output would stop being seen as referenced and
# would be reported as a zero-trace spec that is not one. That is a false
# accusation produced by an optimisation, which is worse than the slowness. So
# the invariant is asserted rather than assumed, on the real repository.
#
# MEASUREMENT NOTE, because it nearly ruined the numbers above: an interactive
# shell in this project has `grep` shadowed by a ugrep function, which reports
# 2-6ms for the same sweep and would have hidden the cost entirely. This fixture
# and every quoted number use /usr/bin/grep, which is what the hook gets.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

GREP=/usr/bin/grep
[ -x "$GREP" ] || GREP=grep

_sweep() { # $1 = extra args
    # shellcheck disable=SC2086
    "$GREP" -rhoE 'spec:[a-zA-Z0-9._-]+' \
        --include='*.rs' --include='*.sh' --include='*.toml' --include='Containerfile*' \
        $1 "$ROOT" 2>/dev/null | sed 's/^spec://' | LC_ALL=C sort -u
}

with_all="$(_sweep "")"
with_excl="$(_sweep "--exclude-dir=target --exclude-dir=.git --exclude-dir=node_modules")"

# NON-VACUITY FIRST. If the sweep returns nothing, the comparison below is
# trivially equal and proves nothing — the shape that lets an optimisation pin
# certify an empty answer.
n_all="$(printf '%s\n' "$with_all" | grep -c . || true)"
if [ "${n_all:-0}" -gt 20 ]; then
    ok "the sweep finds a real corpus ($n_all spec tokens) — the comparison is not vacuous"
else
    bad "the sweep found only ${n_all:-0} tokens; the equality below would prove nothing"
fi

# THE INVARIANT: excluding build output is answer-preserving.
if [ "$with_all" = "$with_excl" ]; then
    ok "excluding target/, .git/ and node_modules does not change the referenced set"
else
    bad "the exclusion CHANGED the answer — a spec referenced only from build output would become a false zero-trace"
    echo "  only with build output included:" >&2
    comm -23 <(printf '%s\n' "$with_all") <(printf '%s\n' "$with_excl") | sed 's/^/    /' | head -10 >&2
    echo "  only with it excluded:" >&2
    comm -13 <(printf '%s\n' "$with_all") <(printf '%s\n' "$with_excl") | sed 's/^/    /' | head -10 >&2
fi

# The hook must actually carry the exclusion; otherwise the invariant above is
# true of a sweep nobody runs.
if "$GREP" -q -- '--exclude-dir=target' "$ROOT/scripts/hooks/pre-commit-openspec.sh"; then
    ok "the hook's sweep carries the exclusion"
else
    bad "scripts/hooks/pre-commit-openspec.sh no longer excludes build output"
fi

echo "precommit-zero-trace-scan-scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

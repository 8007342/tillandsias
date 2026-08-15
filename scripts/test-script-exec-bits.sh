#!/usr/bin/env bash
# @trace order:731-d89b, spec:ci-release
set -uo pipefail

# Fixture for scripts/check-script-exec-bits.sh.
#
# This ABSORBS the four-scenario fixture order 731-d89b wrote here. A rewrite
# under 758-jw6v replaced the file wholesale instead of extending it, which
# broke litmus:script-exec-bit-shape step 2 (it matches the pinned
# "PASS: script-exec-bits fixture" line) and would have dropped the original
# scenario names from the record. Coverage was never lost -- all four are
# below under clearer names -- but the pinned grammar was, and a fixture that
# silently stops satisfying its own litmus is the failure this repo keeps
# filing.
#
# WHY IT EXISTS NOW (order 758-jw6v). The checker was rewritten for speed —
# 16.3s to 1.3s, by replacing 26 sweeps over 612 caller files with one sweep,
# and a four-process filter chain per candidate with one awk pass. Its output on
# the real tree was byte-identical before and after, which proves almost
# nothing: the tree has ZERO violations, so both versions were agreeing on an
# empty answer. An optimisation verified only against a passing tree is
# verified against the one case that cannot detect a broken checker.
#
# So the contract is exercised in both directions, in a THROWAWAY repo. An
# earlier attempt built these cases in the real checkout with `git add -N` plus
# `git update-index --chmod`, which mutates shared index state and produced a
# misleading comparison; do not do that.
#
# THE CONTRACT (from the checker's own header):
#   * a tracked-100644 script with a shebang, invoked BY PATH, is REFUSED
#   * the same script invoked as `bash <path>` is not a defect
#   * the same script SOURCED is not a defect
#   * a script with no shebang is not a candidate at all
#   * a 100755 script invoked by path is fine

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-script-exec-bits.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/script-exec-bits-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=()

# scenario <name> <expected-rc> <expected-stdout-substring> <caller-body> [mode]
scenario() {
    local name="$1" want_rc="$2" want="$3" caller_body="$4" mode="${5:-100644}"
    local repo="$work/$name"
    rm -rf "$repo"; mkdir -p "$repo/scripts"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email f@example.invalid
    git -C "$repo" config user.name fixture
    cp "$CHECK" "$repo/scripts/check-script-exec-bits.sh"
    # The checker gained a helper file (758-jw6v). A fixture that copies the
    # script but not its dependency exercises the missing-dependency path and
    # calls it a pass — which is how 752-8hqx wasted a diagnosis.
    mkdir -p "$repo/scripts/lib"
    cp "$ROOT/scripts/lib/exec-bits-filter.awk" "$repo/scripts/lib/"
    printf '#!/usr/bin/env bash\necho target\n' > "$repo/scripts/target.sh"
    printf '#!/usr/bin/env bash\n%s\n' "$caller_body" > "$repo/scripts/caller.sh"
    git -C "$repo" add -A >/dev/null 2>&1
    # The mode is the whole point of the check, so set it explicitly rather
    # than relying on whatever the filesystem reported.
    if [ "$mode" = "100644" ]; then
        git -C "$repo" update-index --chmod=-x scripts/target.sh
    else
        git -C "$repo" update-index --chmod=+x scripts/target.sh
    fi

    local rc=0 out
    out="$(cd "$repo" && bash scripts/check-script-exec-bits.sh 2>/dev/null)" || rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$want"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name: want rc=$want_rc matching [$want], got rc=$rc [$out]"
        failures+=("$name")
    fi
}

# 1. THE DEFECT ITSELF. Without this passing, the checker is decoration.
scenario "bare-invocation-refused" 1 "violation:script-not-executable:1" \
    'scripts/target.sh'

# 2-3. NOT defects: naming an interpreter works at any mode, and a sourced
# library should not be executable at all.
scenario "interpreter-prefixed-ok" 0 "ok:script-exec-bits:" \
    'bash scripts/target.sh'
scenario "sourced-ok" 0 "ok:script-exec-bits:" \
    '. scripts/target.sh'

# 4. Already executable: nothing to fix.
scenario "executable-bare-ok" 0 "ok:script-exec-bits:" \
    'scripts/target.sh' 100755

# 5. A bare invocation inside a command substitution is still an invocation —
# this is the shape that produced the original defect
# (`run_id="$(scripts/resolve-release-run.sh ...)"`).
scenario "command-substitution-refused" 1 "violation:script-not-executable:1" \
    'x="$(scripts/target.sh)"; echo "$x"'

# 6. Piped/chained position counts too.
scenario "after-pipe-refused" 1 "violation:script-not-executable:1" \
    'echo hi | scripts/target.sh'

# 7. The checker must REFUSE when its filter helper is absent, not report a
# clean tree it never examined. Without this the perf split could regress into
# a checker that always passes.
repo="$work/missing-helper"
rm -rf "$repo"; mkdir -p "$repo/scripts"
git -C "$repo" init -q -b main
git -C "$repo" config user.email f@example.invalid
git -C "$repo" config user.name fixture
cp "$CHECK" "$repo/scripts/check-script-exec-bits.sh"
printf '#!/usr/bin/env bash
echo target
' > "$repo/scripts/target.sh"
printf '#!/usr/bin/env bash
scripts/target.sh
' > "$repo/scripts/caller.sh"
git -C "$repo" add -A >/dev/null 2>&1
git -C "$repo" update-index --chmod=-x scripts/target.sh
rc=0
out="$(cd "$repo" && bash scripts/check-script-exec-bits.sh 2>/dev/null)" || rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "violation:script-not-executable:0"; then
    echo "PASS  missing-helper-refuses"
else
    echo "FAIL  missing-helper-refuses: want rc=2 with a violation line, got rc=$rc [$out]"
    failures+=("missing-helper-refuses")
fi

if [ "${#failures[@]}" -gt 0 ]; then
    echo "FAIL: ${#failures[@]} scenario(s): ${failures[*]}"
    exit 1
fi
# The pinned line litmus:script-exec-bit-shape step 2 matches. It predates this
# file being rewritten and must survive: order 731-d89b wrote the original
# four-scenario fixture, and a later edit here replaced it wholesale, silently
# breaking that step. All four of the original scenarios are still covered,
# under clearer names:
#   bare-invocation-non-executable      -> bare-invocation-refused
#   bare-invocation-executable          -> executable-bare-ok
#   interpreter-prefixed-non-executable -> interpreter-prefixed-ok
#   sourced-library-non-executable      -> sourced-ok
echo "PASS: script-exec-bits fixture 7/7 scenarios green (bare-invocation-refused, interpreter-prefixed-ok, sourced-ok, executable-bare-ok, command-substitution-refused, after-pipe-refused, missing-helper-refuses)"
echo "ok:script-exec-bits-fixture:7"
exit 0

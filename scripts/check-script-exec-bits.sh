#!/usr/bin/env bash
# @trace order:731-d89b, spec:ci-release
#
# check-script-exec-bits.sh — refuse a script that callers RUN by path but git
# tracks as non-executable.
#
# THE DEFECT THIS CLOSES. scripts/resolve-release-run.sh was committed from the
# Windows host at mode 100644. The release runbook invokes it directly —
# `run_id="$(scripts/resolve-release-run.sh "${new_tag}")"` — which on Linux is
# a permission error, not a verdict. The irony is exact: that script exists to
# stop a release step from mistaking absence for health, and it would itself
# have failed in a way the caller reads as output. Nothing would have caught it
# until the next release ran; it surfaced only because a new litmus asserted
# `test -x`. The osx host landed two more mode flips in the same window, so the
# class is live across all three platforms.
#
# WHAT IS *NOT* A DEFECT, and why the rule is narrow. Most scripts here are
# invoked as `bash scripts/x.sh`, which works at any mode, and several
# (common.sh, help*.sh) are SOURCED libraries that should not be executable at
# all. A blanket "shebang implies +x" rule would flag 27 files, nearly all of
# them correct. The property that actually breaks is narrower: **someone runs
# this path without naming an interpreter.**
#
# So callers are read from places that EXECUTE — shell scripts, build.sh, skill
# runbooks, and litmus `command:` lines — never from prose. plan/index.yaml
# mentions script paths constantly in event summaries; treating those as callers
# would make this checker a random-noise generator.
#
# GRAMMAR (exactly one line on stdout)
#   ok:script-exec-bits:<n> checked
#   violation:script-not-executable:<n>
#
# Exit 0 when every bare-invoked script is mode 100755.
#
# Pinned by litmus:script-exec-bit-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Files that EXECUTE things. Prose is deliberately excluded — see above.
caller_files="$(git ls-files 'scripts/*.sh' 'build.sh' 'skills/*/SKILL.md' 'openspec/litmus-tests/*.yaml' 2>/dev/null)"
if [ -z "$caller_files" ]; then
    echo "ok:script-exec-bits:0 checked"
    echo "  note: no caller files found (not a git checkout?)" >&2
    exit 0
fi

checked=0
violations=0

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    mode="${entry%% *}"
    path="${entry##*$'\t'}"
    [ "$mode" = "100644" ] || continue
    [ -f "$path" ] || continue
    # Only files that are meant to be run at all.
    head -c2 "$path" 2>/dev/null | grep -q '#!' || continue

    # A BARE invocation: the path at the start of a command, not preceded by an
    # interpreter (`bash`/`sh`) and not sourced (`source` / `.`).
    #
    # TWO alternatives, not one, and the split is load-bearing (order 758-jw6v).
    # The single pattern ended `([[:space:]"]|$)`, which cannot match
    # `$(scripts/x.sh)` because the next character is `)`. So this checker could
    # not see the invocation form that MOTIVATED it — its own header quotes
    # `run_id="$(scripts/resolve-release-run.sh "${new_tag}")"` as the defect.
    # Found by scripts/test-script-exec-bits.sh, which was written because a
    # perf rewrite produced byte-identical output on a tree with zero
    # violations, and identical-on-empty proves nothing.
    #
    # Simply adding `)` to the trailing class fixes the substitution case and
    # breaks three others: `(` is already in the LEADING class, so `(path)`
    # anywhere in PROSE starts matching. Measured — it flagged three comments,
    # one of them naming plan-binary-probe.sh, a SOURCED library that must stay
    # non-executable. That is the "gate that greps its own comment" shape
    # 601-462g names. So `)` is allowed only after `$(`.
    hit="$(printf '%s\n' "$caller_files" \
        | xargs -r grep -nE "((^|[;&|(])[[:space:]]*\"?${path}([[:space:]\"]|$))|(\\\$\\([[:space:]]*\"?${path}([[:space:]\")]|$))" 2>/dev/null \
        | grep -vE "(bash|sh|source|\.)[[:space:]]+\"?${path}" \
        | grep -v "^${path}:" \
        | head -1)"
    checked=$((checked + 1))
    if [ -n "$hit" ]; then
        violations=$((violations + 1))
        {
            echo "REFUSED: $path is invoked by path but tracked as mode 100644 —"
            echo "         on a POSIX host that invocation is a permission error, not a verdict."
            echo "         Fix: git update-index --chmod=+x $path"
            printf '   caller: %s\n' "$(printf '%s' "$hit" | cut -c1-140)"
        } >&2
    fi
done <<EOF
$(git ls-files -s scripts/ 2>/dev/null)
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:script-not-executable:$violations"
    exit 1
fi
echo "ok:script-exec-bits:$checked checked"
exit 0

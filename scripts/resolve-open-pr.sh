#!/usr/bin/env bash
# @trace order:601-462g, spec:ci-release
#
# Resolve the open linux-next -> main PR number, and REFUSE when there is none.
#
# THE DEFECT THIS CLOSES. skills/merge-to-main-and-release step 2 read:
#
#     existing_pr=$(gh pr list --base main --head linux-next --state open \
#                     --json number --jq '.[0].number')
#     if [[ -z "$existing_pr" ]]; then
#         gh pr create ...
#         existing_pr=$(gh pr list ... --jq '.[0].number')
#     fi
#     echo "PR #${existing_pr}"
#
# `--jq '.[0].number'` on an EMPTY array prints the literal `null`, not an empty
# string. So with no open PR the emptiness test is FALSE, `gh pr create` never
# runs, and the runbook announces `PR #null` and walks into step 3 to merge a
# pull request that does not exist. The second query has the same shape, so a
# creation that silently failed also yields `PR #null`.
#
# This is the third instance of one class in one file, and the file DOCUMENTS
# the class twice already: step 3's note on `gh pr checks --watch` exiting 0
# with no checks, and step 7's note that `--jq '.[0].databaseId'` prints `null`
# on an empty result set. Knowing the shape did not stop it recurring three
# steps earlier in the same runbook, which is the argument for a resolver over
# another caution. scripts/resolve-release-run.sh is its sibling; this file is
# deliberately its twin so the pair reads as one pattern.
#
# GRAMMAR (exactly one line on stdout)
#   ok:open-pr:<number>
#   blocked:open-pr:none-open:<head>-><base>
#   blocked:open-pr:gh-failed:<head>-><base>
#
# Exit 0 on ok, 1 on blocked. $GH overrides the gh binary for fixtures.
#
# Pinned by litmus:release-runbook-external-preconditions-shape.

set -uo pipefail

base="${1:-main}"
head="${2:-linux-next}"

GH="${GH:-gh}"

# `gh` failing (network, auth, no repo) and `gh` succeeding with nothing to say
# are DIFFERENT facts. Collapsing them is a smaller version of the bug this
# script exists to fix, so stdout and the exit status are captured separately.
out="$("$GH" pr list --base "$base" --head "$head" --state open \
        --json number --jq '.[0].number' 2>/dev/null)"
rc=$?

if [ "$rc" -ne 0 ]; then
    echo "blocked:open-pr:gh-failed:$head->$base"
    exit 1
fi

number="$(printf '%s' "$out" | tr -d '[:space:]')"
if [ -z "$number" ] || [ "$number" = "null" ]; then
    echo "blocked:open-pr:none-open:$head->$base"
    exit 1
fi

echo "ok:open-pr:$number"
exit 0

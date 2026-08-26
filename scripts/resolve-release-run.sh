#!/usr/bin/env bash
# @trace order:601-462g, spec:ci-release
# freshness: auditor=linux-lenovinha-fable5-20260823t195304z date=2026-08-23 verdict=refreshed scope=full file, 70 lines. Twin of resolve-open-pr.sh (audited 2026-08-23, same verdict) and the pair still reads as one pattern, which is the property worth preserving — they guard the same `gh` failure mode on the two different objects the release runbook extracts. Still sound: fixture scripts/test-resolve-release-run.sh 6/6 green here, and litmus:release-runbook-external-preconditions-shape pins the distinct `blocked:release-run:gh-failed:` grammar against its sibling's. Its sixth scenario (no-tag-given) has no counterpart in the twin and is correct: the tag is an argument here and the branch pair is not. No change needed.
#
# Resolve the release workflow run for a tag, and REFUSE when there is none.
#
# THE DEFECT THIS CLOSES (order 601-462g's class, found in its own runbook).
# skills/merge-to-main-and-release step 7 read:
#
#     run_id=$(gh run list --workflow=release.yml --branch="${new_tag}" \
#                --limit 1 --json databaseId --jq '.[0].databaseId')
#     gh run watch "${run_id}"        # blocks until green or red
#
# When the dispatch in step 6 did not actually start a run -- wrong ref, a
# workflow_dispatch that silently no-oped, a tag that never reached the remote
# -- `gh run list` prints NOTHING and exits 0. The command substitution then
# succeeds with an EMPTY run_id, and the runbook walks into `gh run watch ""`
# having never noticed that the thing it is waiting for does not exist.
#
# Absent and healthy sharing an exit code is exactly the shape 601-462g was
# filed to hunt, and the same file already documents a SIBLING of it four
# steps earlier: "The trap: `gh pr checks --watch` does NOT fail when there
# are no checks." The class was known and this instance was missed anyway,
# which is the argument for a checker over a caution.
#
# It matters more now than when it was filed: push CI was removed (599-w5jd),
# so this workflow is the release, and the Windows half of it now carries
# Authenticode signing (722/724). A release that is never watched is a release
# nobody confirms was signed.
#
# GRAMMAR (exactly one line on stdout)
#   ok:release-run:<run-id>
#   blocked:release-run:no-run-for-tag:<tag>
#   blocked:release-run:gh-failed:<tag>
#
# Exit 0 on ok, 1 on blocked. $GH overrides the gh binary for fixtures.

set -uo pipefail

tag="${1:-}"
if [ -z "$tag" ]; then
    echo "blocked:release-run:no-tag-given"
    exit 1
fi

GH="${GH:-gh}"

# Capture stdout and the exit status separately. `gh` failing (network, auth)
# and `gh` succeeding with nothing to say are DIFFERENT facts and the caller
# needs to tell them apart -- collapsing them is a smaller version of the same
# bug this script exists to fix.
out="$("$GH" run list --workflow=release.yml --branch="$tag" \
        --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
rc=$?

if [ "$rc" -ne 0 ]; then
    echo "blocked:release-run:gh-failed:$tag"
    exit 1
fi

run_id="$(printf '%s' "$out" | tr -d '[:space:]')"
# `--jq '.[0].databaseId'` on an empty array prints the literal "null", not an
# empty string, so testing for emptiness alone would let "null" through and
# hand `gh run watch null` a plausible-looking argument.
if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
    echo "blocked:release-run:no-run-for-tag:$tag"
    exit 1
fi

echo "ok:release-run:$run_id"
exit 0

#!/bin/bash
set -uo pipefail

# @trace spec:meta-orchestration
# check-credential-channel.sh: executable Credential Channel Guard (plan order 61).
#
# Makes the meta-orchestration start-of-cycle Credential Channel Guard a
# verifiable check that returns a pass/fail exit code, instead of advisory prose
# that only an attentive agent honors (philosophy.yaml requires falsifiable
# verification claims; a guard nothing enforces is a suggestion, not a
# constraint).
#
# A usable git push credential channel is present when ANY of these holds:
#   - <git-dir>/.gh-credentials exists and is non-empty (repo-local store), or
#   - GH_TOKEN or GITHUB_TOKEN is set in the environment, or
#   - `gh auth status` succeeds (reachable, unlocked keyring).
#
# Emits exactly one line on stdout matching the falsifiable grammar
#   ^(ok:[a-z0-9-]+|missing:no-credential-channel)$
# and exits 0 (channel present) or 1 (channel absent).
#
#   ok:gh-credentials-store        repo-local store helper file present + non-empty
#   ok:gh-token-env                GH_TOKEN set
#   ok:github-token-env            GITHUB_TOKEN set
#   ok:gh-keyring                  `gh auth status` green
#   ok:forge-git-mirror            TILLANDSIAS_HOST_KIND=forge (transparent git mirror)
#   missing:no-credential-channel  none of the above
#
# NOTE: anonymous reads (`git fetch`/`git ls-remote`) succeeding on a public
# repo is NOT evidence of a credential channel. This check verifies the
# prerequisites for write capability only; it deliberately does not perform a
# network push.
#
# Testability seam: set TILLANDSIAS_CRED_SKIP_GH=1 to suppress the `gh auth
# status` probe so a scrubbed-environment fixture fails closed deterministically
# regardless of the host's ambient gh keyring state (used by
# litmus:credential-channel-check-shape).

credential_channel_verdict() {
  local git_dir cred_file
  if git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
    cred_file="${git_dir}/.gh-credentials"
    if [ -s "$cred_file" ]; then
      echo "ok:gh-credentials-store"
      return 0
    fi
  fi
  if [ -n "${GH_TOKEN:-}" ]; then
    echo "ok:gh-token-env"
    return 0
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "ok:github-token-env"
    return 0
  fi
  if [ "${TILLANDSIAS_CRED_SKIP_GH:-0}" != "1" ] \
     && command -v gh >/dev/null 2>&1 \
     && gh auth status >/dev/null 2>&1; then
    echo "ok:gh-keyring"
    return 0
  fi
  if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    echo "ok:forge-git-mirror"
    return 0
  fi
  echo "missing:no-credential-channel"
  return 1
}

# Standalone mode: print the single verdict line and exit with its pass/fail code.
verdict="$(credential_channel_verdict)" && rc=0 || rc=$?
echo "$verdict"
exit "$rc"

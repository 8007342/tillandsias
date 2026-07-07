#!/bin/bash
set -uo pipefail

if grep -qi "microsoft" /proc/version 2>/dev/null && pwd | grep -q '^/mnt/[c-z]/'; then
  echo "[check-credential-channel] WARNING: Running in WSL but directory is on Windows host. Host credentials may be unavailable. On Windows, use Git Bash instead." >&2
fi
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
    # The forge uses a transparent git mirror service for authenticated pushes.
    # But HOST_KIND=forge being SET does not prove the mirror is REACHABLE for
    # this checkout: a shared-host-checkout or misconfigured-DNS forge can have
    # the env var set while every fetch/push through the mirror fails ("access
    # denied or repository not exported", "unable to look up tillandsias-git").
    # That false-positive made a Codex forge cycle accrete a commit it could
    # never push — the exact velocity-killer this guard exists to prevent. See
    # plan/issues/forge-shared-host-checkout-mirror-alias-2026-07-04.md. So VERIFY
    # the mirror actually answers for `origin` before declaring the channel
    # present. Unlike a direct anonymous GitHub read, an ls-remote THROUGH the
    # mirror exercises the same rewrite path a push takes and proves the mirror
    # sidecar is up for this repo; a failure is definitive evidence it is unusable.
    if [ "${TILLANDSIAS_CRED_SKIP_MIRROR_PROBE:-0}" = "1" ]; then
      # Fixture seam: trust the env var without a network probe (deterministic).
      echo "ok:forge-git-mirror"
      return 0
    fi
    if timeout 10 git ls-remote origin HEAD >/dev/null 2>&1; then
      echo "ok:forge-git-mirror"
      return 0
    fi
    echo "[check-credential-channel] TILLANDSIAS_HOST_KIND=forge but the git mirror is unreachable for this checkout (git ls-remote origin failed): no usable push channel. Fix the mirror export/DNS or provide a forge credential channel; do NOT import host credentials." >&2
    echo "missing:no-credential-channel"
    return 1
  fi
  echo "missing:no-credential-channel"
  return 1
}

# Standalone mode: print the single verdict line and exit with its pass/fail code.
verdict="$(credential_channel_verdict)" && rc=0 || rc=$?
echo "$verdict"
exit "$rc"

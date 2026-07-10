#!/bin/bash
set -uo pipefail

# @trace spec:meta-orchestration
# litmus-git-delta-wait.sh: bounded-retry git-delta probe for forge-launching
# litmus steps (plan order 255, opencode-prompt-e2e-step5-race).
#
# Problem class: a litmus step launches a real in-forge cycle (STEP 3 of
# litmus:opencode-prompt-e2e-shape), then later steps assert the cycle's
# commits are visible. The forge's commits reach the host checkout through
# the git-mirror relay asynchronously relative to the forge session's exit,
# so a single instantaneous sample races the relay. Additionally, the
# original STEP 5 referenced $HEAD_BEFORE without populating it (each
# runner step is a fresh `bash -c` subshell — variables do not carry across
# steps), which collapsed its diff range to HEAD..HEAD and made the step
# fail deterministically. Third occurrence of the sampling race class
# (b0ccc88f, c40f80c1); this helper is the shared fix.
#
# Usage:
#   scripts/litmus-git-delta-wait.sh local-head   <before-file> [timeout-s]
#   scripts/litmus-git-delta-wait.sh plan-commit  <before-file> [timeout-s]
#   scripts/litmus-git-delta-wait.sh remote-head  <before-file> [timeout-s]
#
#   local-head   waits until `git rev-parse HEAD` differs from the sha in
#                <before-file>.
#   plan-commit  waits until at least one commit in <before-sha>..HEAD
#                touches plan/ (`git rev-list --count <before>..HEAD -- plan/`).
#   remote-head  waits until `git ls-remote origin HEAD` differs from the
#                sha in <before-file>.
#
# Polls immediately, then every LITMUS_GIT_DELTA_POLL_S (default 5) seconds
# until the condition holds or the bounded window (arg 3, else
# LITMUS_GIT_DELTA_TIMEOUT_S, else 120 seconds) elapses. The warm path —
# condition already true — returns in one probe with no sleep.
#
# Emits exactly one verdict line on stdout matching the falsifiable grammar
#   ^(ok: .*|FAIL: .*)$
# followed on failure by diagnostic lines. Success lines are stable API
# (litmus expected_behavior matches on them):
#   ok: HEAD advanced <before> -> <after>
#   ok: plan/ changed
#   ok: remote HEAD advanced <before> -> <after>
# Exit codes: 0 condition observed; 1 bounded window elapsed without the
# condition (a run that genuinely never satisfies it still fails — no dead
# check); 2 usage error or unreadable/invalid <before-file> (fail loud).

POLL_S="${LITMUS_GIT_DELTA_POLL_S:-5}"

usage() {
  echo "FAIL: usage: $0 {local-head|plan-commit|remote-head} <before-file> [timeout-s]"
  exit 2
}

[ $# -ge 2 ] || usage
mode="$1"
before_file="$2"
timeout_s="${3:-${LITMUS_GIT_DELTA_TIMEOUT_S:-120}}"

case "$mode" in
  local-head|plan-commit|remote-head) ;;
  *) usage ;;
esac

if [ ! -s "$before_file" ]; then
  echo "FAIL: before-file missing or empty: $before_file"
  exit 2
fi
before="$(head -n1 "$before_file" | tr -d '[:space:]')"
if ! printf '%s' "$before" | grep -qE '^[0-9a-f]{7,64}$'; then
  echo "FAIL: before-file does not contain a sha: $before_file ('$before')"
  exit 2
fi

deadline=$(( $(date +%s) + timeout_s ))

probe_local_head() {
  local after
  after="$(git rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$after" ] && [ "$after" != "$before" ] || return 1
  echo "ok: HEAD advanced $before -> $after"
}

probe_plan_commit() {
  local n
  n="$(git rev-list --count "${before}..HEAD" -- plan/ 2>/dev/null)" || return 1
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 1
  echo "ok: plan/ changed"
}

probe_remote_head() {
  local after
  after="$(git ls-remote origin HEAD 2>/dev/null | awk '{print $1; exit}')" || return 1
  [ -n "$after" ] && [ "$after" != "$before" ] || return 1
  echo "ok: remote HEAD advanced $before -> $after"
}

while :; do
  case "$mode" in
    local-head)  probe_local_head  && exit 0 ;;
    plan-commit) probe_plan_commit && exit 0 ;;
    remote-head) probe_remote_head && exit 0 ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep "$POLL_S"
done

case "$mode" in
  local-head)
    echo "FAIL: HEAD unchanged ($before) after ${timeout_s}s"
    ;;
  plan-commit)
    echo "FAIL: no plan/ file modified in new commit(s) after ${timeout_s}s — meta-orch must update a plan file before push"
    echo "commits in window:"
    git log --oneline "${before}..HEAD" 2>/dev/null | head -10 || echo "(range unresolvable from $before)"
    echo "files changed in window:"
    git diff --name-only "${before}..HEAD" 2>/dev/null | head -20 || echo "(no diff)"
    ;;
  remote-head)
    echo "FAIL: remote HEAD unchanged ($before) after ${timeout_s}s"
    ;;
esac
exit 1

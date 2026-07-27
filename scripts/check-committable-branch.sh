#!/bin/sh
# freshness: refreshed 2026-07-27 linux-claude-order476-20260727
# @trace spec:meta-orchestration
# check-committable-branch.sh: executable Committable Branch Guard (plan order 476).
#
# Makes the "Release: `main` through PR only" rule a verifiable check that
# returns a pass/fail exit code, instead of advisory prose that only an
# attentive agent honors (philosophy.yaml requires falsifiable verification
# claims; a guard nothing enforces is a suggestion, not a constraint). Breach
# record: commit 34e60965 — an antigravity forge cycle running ON `main`
# pushed a ~42k-line plan/index.yaml reserialization directly to origin/main,
# bypassing the PR promotion discipline; reverted via PR #81. See
# plan/issues/main-branch-direct-push-guard-2026-07-24.md.
#
# The current checkout is a legitimate committable branch when HEAD is on a
# named branch that is not `main`. Committable cycles on `main` are forbidden
# (main advances only via PR merge). Detached HEAD and non-repo directories
# fail closed: a committable cycle needs a branch it can push.
#
# Emits exactly one line on stdout matching the falsifiable grammar
#   ^(ok:branch-[A-Za-z0-9._/-]+|blocked:(committable-cycle-on-main|detached-head|not-a-git-repo))$
# and exits 0 (committable branch) or 1 (blocked).
#
#   ok:branch-<name>                   HEAD is on branch <name> (not main)
#   blocked:committable-cycle-on-main  HEAD is on main — commit/push forbidden
#   blocked:detached-head              detached HEAD — no branch to push (fail closed)
#   blocked:not-a-git-repo             cwd is not inside a git worktree (fail closed)
#
# NOTE: this guard gates COMMITTABLE cycles only. Read-only/inspection cycles
# on a `main` checkout remain allowed — callers consult the verdict before
# claiming, committing, or pushing work, not before reading.
#
# Branch detection uses `git symbolic-ref --quiet --short HEAD` (the packet's
# `git rev-parse --abbrev-ref HEAD` semantic): it resolves the branch name
# even on an unborn branch (fresh `git init -b main`, where rev-parse fails)
# and exits non-zero on detached HEAD.

set -u

committable_branch_verdict() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "blocked:not-a-git-repo"
    return 1
  fi
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    echo "blocked:detached-head"
    return 1
  fi
  if [ "$branch" = "main" ]; then
    echo "blocked:committable-cycle-on-main"
    return 1
  fi
  echo "ok:branch-${branch}"
  return 0
}

# Standalone mode: print the single verdict line and exit with its pass/fail code.
verdict="$(committable_branch_verdict)" && rc=0 || rc=$?
echo "$verdict"
exit "$rc"

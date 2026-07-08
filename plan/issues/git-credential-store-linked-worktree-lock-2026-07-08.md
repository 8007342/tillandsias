# Git Credential Store Linked Worktree Lock Warning

**Date:** 2026-07-08
**Classification:** optimization
**Host:** linux_mutable
**Observed by:** linux-macuahuitl-codex-20260708T1919Z

## Observation

During the mutable-Linux sibling integration push from a linked worktree
(`/tmp/tillandsias-integrate-20260708`), `git push origin HEAD:linux-next`
succeeded but printed this warning first:

```text
fatal: unable to get credential storage lock in 1000 ms: Not a directory
```

The linked worktree inherited the main checkout's local credential helper:

```text
credential.helper = store --file=.git/.gh-credentials
```

In the main checkout, `.git` is a directory and `.git/.gh-credentials` exists.
In a linked worktree, `.git` is a file that points at
`/home/tlatoani/3src/tillandsias/.git/worktrees/<name>`, so Git's credential
store helper tries to lock `.git/.gh-credentials.lock` below a regular file and
emits `Not a directory`. The push still completed, likely because another
credential channel in the helper chain supplied credentials, but the warning is
noisy and makes push health harder to audit.

## Impact

Coordinator integration work intentionally uses fresh linked worktrees. Every
integration push from such a worktree can report a scary `fatal:` line even when
the push succeeds, which makes the push/failure contract harder to interpret and
can hide a real credential failure in noisy logs.

## Smallest Next Action

Teach the host credential seeding/check path to avoid relative `.git/...`
credential-store paths when linked worktrees are possible. Use
`git rev-parse --git-common-dir` or an absolute path to the common repository
credential store, and add a targeted litmus that creates a linked worktree and
asserts `git credential-store --file <configured-path>` can lock the file without
`Not a directory`.

## Verifiable Closure

A linked worktree created from this repository can run:

```bash
git config --get-all credential.helper
git push origin HEAD:refs/heads/linux-next
```

without emitting `unable to get credential storage lock` or `Not a directory`,
while `scripts/check-credential-channel.sh` still reports a usable credential
channel on the same checkout.

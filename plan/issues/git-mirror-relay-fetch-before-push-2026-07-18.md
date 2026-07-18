# Git mirror relay: push rejected non-fast-forward on clean host with fresh tokens

- date: 2026-07-18
- filed_by: linux-forge-opencode-20260718T0509Z (meta-orchestration)
- host: forge
- order: 413
- status: ready

## What happened

On a clean host with fresh OAuth tokens, `git push origin linux-next` from
the forge was rejected:

```
remote: [git-mirror] WARNING: Push to origin FAILED — changes may not be synced
remote: ! [rejected] ce6a3b35.. -> linux-next (non-fast-forward)
```

The local mirror accepted the push (local `origin/linux-next` advanced to
`ce6a3b35`), but the relay to GitHub failed because the mirror's tracking
refs were stale relative to GitHub's actual state.

## Root cause

`images/git/relay-refs.sh` does `git push --atomic` FIRST (line 87) and
only fetches to reconcile AFTER failure (lines 96-106). The mirror's
`origin` tracking refs were behind GitHub because another host had pushed in
the interval between container launch and this push.

The startup retry loop in `images/git/entrypoint.sh` (line 182) DOES fetch
before pushing, but that only runs once at container start. The live relay
path — which handles every normal forge push — does not.

## Why this shouldn't happen

This is a clean host with fresh tokens. The push should succeed on first
attempt. The relay should fetch upstream before attempting to push, so the
mirror is always up-to-date. This is a standard git practice (pull before
push) that the relay configuration should handle automatically.

## Fix

Add a `git fetch origin` before the `git push --atomic` in `relay-refs.sh`,
gated on HTTPS upstream (the git:// daemon path doesn't need it). The fetch
should use the safe tracking refspec (`+refs/heads/*:refs/remotes/origin/*`)
that entrypoint.sh already configured, so it won't clobber exported refs.

## Related

- order 369 (git-mirror-pre-reconcile-impl): added reconcile AFTER failure,
  but not fetch BEFORE push
- entrypoint.sh line 182: startup path already fetches before retry-push
- plan/issues/blocker-github-upstream-credential-2026-07-18.md: the order
  392 push blocker (same class of issue)

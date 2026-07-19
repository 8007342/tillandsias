# Blocker: GitHub-upstream push credential unavailable (forge relay)

- date: 2026-07-18
- filed_by: linux-forge-20260718T0334Z (meta-orchestration / advance-work-from-plan, inference-startup-cleanup cycle)
- host: forge
- blocker_type: no-credential-channel (GitHub upstream leg)
- owner: operator
- classification: blocked (failed-retryable)

## What happened

The inference-startup-cleanup (order 392) implementation is complete and
committed locally as `f7701ffd` on `linux-next`. The local forge git mirror
channel accepted the push intent, but the relay to github.com rejected it:

```
remote: [relay] HTTPS upstream credential is unavailable; run GitHub Login before pushing
remote: [pre-receive] Push rejected: configured upstream did not durably accept the ref transaction
 ! [remote rejected]   linux-next -> linux-next (pre-receive hook declined)
```

The Credential Channel Guard (`scripts/check-credential-channel.sh`) had
reported `ok:forge-git-mirror` for the LOCAL mirror channel at cycle start —
that channel is fine. The break is the SECOND leg: the forge relay's GitHub
HTTPS upstream credential is currently unavailable. (The immediately prior
cycle, `6e8f2384`, pushed successfully, so the upstream creds lapsed between
cycles or the relay's GitHub session expired.)

No `GH_TOKEN` / `GITHUB_TOKEN` is set in the environment, and `gh auth status`
cannot read its config (permission denied on `/home/forge/.config/gh/config.yml`).

## Smallest next action (operator)

Restore the GitHub upstream credential for the relay, then re-push:

1. `tillandsias --github-login --with-token` (paste a GitHub PAT with `repo`
   scope) OR set `GH_TOKEN` in the task environment, then
2. `git push origin linux-next` (local commit `f7701ffd` is ready; tree clean,
   not ahead of the local mirror, 1 commit pending on the GitHub upstream leg).

No code change is required — the work is complete and committed; only the
upstream transport credential is missing.

## Impact

- `f7701ffd` (order 392 deterministic inference readiness + truthful effective
  tier) is NOT yet on github.com. All other progress (411 from the prior cycle)
  is already upstream.
- Packet `inference-startup-cleanup` is marked `blocked` (failed-retryable)
  until the push lands.

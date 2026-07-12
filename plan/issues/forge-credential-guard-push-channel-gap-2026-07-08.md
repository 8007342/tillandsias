# Credential Guard: `ok:forge-git-mirror` false-positive when origin points to GitHub directly (not through mirror)

**Filed**: 2026-07-08T18:56Z
**Host**: forge container, main
**Classification**: blocker/regression
**Related packets**: forge-credential-guard-mirror-reachability (order 173), forge-validation-findings-2026-07-04 (order 177)

## Summary

The credential guard (`scripts/check-credential-channel.sh`) returns `ok:forge-git-mirror` but `git push --dry-run origin main` fails with `fatal: could not read Username for 'https://github.com': No such device or address`. The guard's mirror-reachability probe only verifies GitHub is reachable for anonymous reads — it does not verify that a push credential channel exists.

## Current State

```
GH_TOKEN:                  unset
GITHUB_TOKEN:              unset
.gh-credentials:           absent
gh auth status:            failed (permission denied on config)
git push --dry-run main:   FAIL (could not read Username)
credential guard verdict:  ok:forge-git-mirror (FALSE POSITIVE)
```

## Root Cause

The order-173 fix introduced a `git ls-remote origin HEAD` probe to verify the mirror is reachable. But in this forge:

1. `origin` = `https://github.com/8007342/tillandsias.git` (direct GitHub, NOT `git://tillandsias-git/tillandsias`)
2. No `url.insteadOf` global git rewrite is active
3. `git ls-remote origin HEAD` succeeds against GitHub because the repo is public (anonymous read allowed)
4. This proves nothing about push credentials

The probe was designed for the mirror topology where `origin` is the mirror (`git://tillandsias-git/tillandsias`). When `origin` points to GitHub directly, the probe is testing GitHub connectivity, not credential channel presence.

## Safety Implications

The meta-orchestration Non-Negotiable Exit Contract requires that "No uncommitted tracked changes" and "No local-only commits" be enforced by the credential guard. If a forge cycle produces plan commits that it cannot push — because neither the mirror path nor a direct credential channel exists — the work is stranded. This is exactly the velocity-killer the guard exists to prevent.

## Two Sub-Cases

### A. Forge `origin` bypassing the mirror

When the forge is launched with a direct-to-GitHub origin and no `insteadOf` rewrite, the guard must detect that no credential channel exists (GH_TOKEN, .gh-credentials, gh auth) instead of trusting the mirror probe.

Smallest next action: add a check in the forge-git-mirror branch that verifies the `origin` remote actually resolves to the mirror hostname (`tillandsias-git` or `git-service`). If `origin` points to GitHub directly, fall through to the standard credential checks (token env, gh auth, .gh-credentials) instead of reporting ok based on read-only ls-remote.

### B. Otherwise functional forge with stale mirror refs

From order 177: even when mirror forwarding succeeds, the mirror advertises a stale ref afterward. The exit criteria "after a forge mirror push, mirror ls-remote and direct GitHub ls-remote agree on linux-next" is not testable in this forge because push does not go through the mirror.

## Cycle Observations

**2026-07-12T22:30Z** — forge cycle on `osx-next` (a74921f1). Guard correctly reports
`missing:no-credential-channel` (false positive from 2026-07-08 is fixed). However the
underlying gap remains: origin resolves to GitHub directly, no GH_TOKEN/.gh-credentials/gh
auth, no `insteadOf` rewrite to the enclave mirror.

**Resolution**: `tillandsias-git` resolves at `10.0.42.18` on the podman network.
`git://tillandsias-git/tillandsias` works for push (dry-run confirmed). Added repo-local
`url.insteadOf` to rewrite origin through the mirror. Cycle unblocked.

Smallest next action: ensure the forge container image injects this `insteadOf` rule
automatically (via gitconfig in the Containerfile or entrypoint) so every forge cycle
starts with a transparent credential channel.

## Verifiable Closure

```bash
# Guard should fail when origin points to GitHub directly and no push creds exist
TILLANDSIAS_HOST_KIND=forge origin=https://github.com/8007342/tillandsias.git \
  timeout 10 git push --dry-run origin main 2>&1 | grep -q "fatal"
# ^ currently guard reports ok despite this
```

A fixture with `TILLANDSIAS_CRED_SKIP_MIRROR_PROBE=1` + direct-GitHub origin + no creds should also fail the guard.

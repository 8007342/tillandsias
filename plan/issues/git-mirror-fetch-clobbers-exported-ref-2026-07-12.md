# Git mirror relay fetch clobbers the just-received exported ref

- Date: 2026-07-12
- Class: bug + behavioral test
- Found on: Forge, normal blind `git push origin linux-next`
- Status: done (order 301) — fixed 2026-07-12 (forge, opus48). Safe reconcile
  refspec + explicit empty-mirror seed in images/git/entrypoint.sh; pinned by
  litmus:git-mirror-ref-convergence (scripts/test-git-mirror-ref-convergence.sh).

## Observation

The first push of `8965d23e` reported successful upstream forwarding and direct
GitHub advanced, but the Forge mirror still advertised the prior `17acd1d0`.
The checkout therefore appeared one commit ahead after an immediate fetch. A
second identical push converged the mirror and GitHub at `8965d23e`.

## Root Cause

The mirror combines two individually plausible behaviors that are unsafe
together:

1. `images/git/entrypoint.sh` sets
   `remote.origin.fetch=+refs/*:refs/*`, mapping upstream branches and tags
   directly onto the bare mirror's exported refs.
2. `images/git/post-receive-hook.sh` runs `git fetch origin` after receive-pack
   has already installed the new branch ref.

When upstream is behind, that fetch force-writes the stale upstream SHA over the
newly received mirror branch. The hook then relays the `NEWSHA` captured from
stdin, so GitHub advances even though the mirror advertises the old SHA. A
repeat push works only because upstream now contains `NEWSHA`.

This also breaks startup retry: fetching before retry can erase the only named
ref to a locally stranded commit, leaving the object dangling and nothing to
forward.

## Deterministic Evidence

An offline fixture with a bare upstream, bare mirror, and working clone exited
0 and reproduced both paths:

- Base `ee964a9913d0e5fff66d425ea2f60dcb02c8a662`
- Probe `f7beb3df1f044b7d2999142dbed407feed8afa76`
- Push 1: mirror `ee964a99`, upstream `f7beb3df`
- Push 2: mirror and upstream `f7beb3df`
- Startup retry fixture: base `ee17014c`, stranded `1983bea6`; fetch reset the
  named refs to the base and left the stranded commit dangling.

## Smallest Next Action

- Fetch upstream branches into `refs/remotes/origin/*` (and avoid implicit tag
  writes during the relay reconciliation fetch).
- Keep explicit local heads/tags seeding for a newly initialized empty mirror;
  do not restore the unsafe all-refs direct mapping.
- Add `scripts/test-git-mirror-ref-convergence.sh` and bind it as
  `litmus:git-mirror-ref-convergence` under `git-mirror-service`.

## Deployment residual (order 302)

The code fix landed in `images/git/entrypoint.sh`, but the **running mirror
container serves the old image** and its bare repo still has
`remote.origin.fetch=+refs/*:refs/*`. Confirmed live during the fix's own push
on 2026-07-12: commit `a1d1ea4c` reached the mirror bare repo, the reconcile
fetch clobbered it back to `884d32f1` (forced-update trace), and convergence
required a redundant second push. Forge hosts have no Podman and cannot rebuild
the image, so a podman-capable host must rebuild `tillandsias-git`, restart the
mirror container (the entrypoint re-applies the safe config on every start — no
volume recreation needed), and live-verify one-push convergence. Tracked as
ready order 302.

## Verifiable Closure

- One Forge push leaves mirror and upstream on the same SHA.
- Startup retry preserves and forwards a locally stranded commit.
- Empty-mirror initialization still provides cloneable heads and tags.
- The offline fixture covers all three cases without network or Podman.
- Existing safe-refspec and YAML-gate litmuses stay green.

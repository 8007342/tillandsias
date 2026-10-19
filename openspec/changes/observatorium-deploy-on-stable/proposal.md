# Proposal — observatorium-deploy-on-stable

Packet: `1798-khw6`. @trace spec:observatorium-dashboard, spec:ci-release

## Why

The first observatorium Worker was created with Cloudflare's "Import a
repository" defaults: a production trigger on `main` and a "Deploy
non-production branches" trigger on every other branch, both watching every
path. In this repository `linux-next`, `windows-next`, `osx-next` and every
`work/*` ref are pushed all day, and each build compiles `tillandsias-plan` and
Flutter (about 5 minutes, measured in `1661-vckd`) against the free plan's
3,000 build minutes a month. The operator deleted the Worker on 2026-10-19 to
stop the burn.

The operator's direction (2026-10-19): the observatorium is rebuilt and
redeployed when a release is promoted to stable, and that is the ONLY time it
is built or deployed automatically.

## What changes

- A deploy branch, `refs/heads/deploy/observatorium`, is the Worker's
  production branch and its only trigger. Non-production branch builds are
  off. Nothing writes the branch except `scripts/promote-stable.sh`.
- `scripts/advance-deploy-ref.sh` (new) moves the branch to a release
  commit's exact tree. It fast-forwards when it can. When the move would be a
  rewind (a demotion, or promoting an older release), it writes a restore
  commit instead: tree = the release's tree, first parent = the release
  commit, second parent = the old tip. The git mirror refuses branch rewinds,
  so the branch only ever moves forward.
- `scripts/promote-stable.sh` gains step 4: after the stable tag is verified
  on origin, it advances the deploy ref and verifies it on origin by tree.
  `demote` advances the ref to the restored release. A failed advance is
  reported `HALF-PROMOTED`, with the remedy command, and is not a promotion.
- `scripts/hooks/pre-push-local-gate.sh`: the tag-on-main exemption (1768-2k56)
  also covers `refs/heads/deploy/*` when the tip is on `main`, or is a restore
  commit whose tree equals its first parent's and that parent is on `main`.
  Both shapes upload no tree the gate has not already passed.
- The Cloudflare settings in `openspec/specs/observatorium-dashboard/deployment.md`
  name the deploy branch, turn off non-production builds and set watch paths
  to `*`.

## Out of scope

- The `stable` tag's own demotion path still resolves `targetCommitish`, which
  can be a branch name (the 1061-zd83 defect, fixed only on the promote path).
  The deploy ref's demote path resolves the release tag's commit.
- Wiring `scripts/lua/test-advance-deploy-ref.lua` as a `--check` gate step
  waits for a darwin or msys run (`check-gate-step-regimes.sh`); filed as a
  follow-up packet.

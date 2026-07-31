# optimization: forge launch regenerates tracked opsx/openspec files, dirty-start refuses the meta-orchestration cycle

- **Date**: 2026-07-31
- **Classification**: optimization (boundary-noise; in-forge cycles)
- **Status**: ready
- **Order**: 540
- **Desired release**: v0.5
- **Discovered by**: forge meta-orchestration cycle 2026-07-31T14:34Z (this checkout)
- **Related**: plan/issues/forge-lane-selfdirty-opencode-lockfile-2026-07-16.md, plan/issues/postbuild-meta-orchestration-dirty-start-contract-2026-07-25.md (order 489)

## What happened (live, 2026-07-31T14:34Z)

The forge launch materialized the checkout and the installed `@fission-ai/openspec`
CLI regenerated its tracked command/skill templates into the project tree:

- `.opencode/commands/opsx-{apply,archive,bulk-archive,continue,explore,ff,new,onboard,propose,sync,verify}.md` (11)
- `.opencode/skills/openspec-{apply-change,archive-change,bulk-archive-change,continue-change,explore,ff-change,new-change,onboard,propose,sync-specs,verify-change}/SKILL.md` (11)

22 tracked paths had mtime == launch time and content matching the CLI's current
generation (adds store selection, required `context`, and `operationGuidance`
handling). The startup boundary guard snapshotted them dirty, so the
meta-orchestration cycle correctly refused with `blocked: dirty-start-worktree`
and reported the blocker in its final handoff — the same self-dirtying-lane
failure mode as the `.opencode/package-lock.json` case (order 328-class), and the
exact desensitization the dirty-start refusal exists to prevent.

## Operator decision (2026-07-31, explicit)

The opsx/openspec skill update is INTENDED and committable; it is versioned
project content, not scratch. The operator directed that this scenario must NOT
block a meta-orchestration cycle. Updating opsx is a NORMAL part of
meta-orchestration: the cycle should MERGE the generated update (commit + push it
as its own `chore(opsx):` change), not refuse.

Immediate unblock: the 22 files were committed to `linux-next` as
`e87705ec chore(opsx): sync openspec commands and skills to current CLI
generation` and pushed. Because the committed bytes equal the CLI's current
output, fresh launches are now clean — until the openspec CLI bumps its templates
again.

## Why this recurs (the real issue)

opsx updates at ITS OWN cadence, independent of Tillandsias. Every launch runs
the installed CLI's generation. When the image's CLI version drifts from the
committed templates, the same 22 paths come back dirty and every in-forge
meta-orchestration cycle refuses until an operator intervenes. This is a standing
hazard, not a one-off.

## Constraint

Do NOT weaken the dirty-start refusal for genuinely dirty operator/sibling trees.
The fix must distinguish launch-generated opsx dirt from real user work, and
must keep the byte-identical preservation guarantee for anything not in the
opsx/openspec generated set.

## Reduction candidates (owner: forge meta-orchestration + forge-image seam)

1. **Meta-orchestration merges generated opsx dirt (primary)**: add a step to the
   in-forge cycle that detects the deterministic launch artifact — the ONLY dirty
   paths are the 22-file opsx/openspec generated set and (forge-hosted, freshly
   materialized clones) nothing else — and commits them as a normal
   `chore(opsx): sync` change on the canonical branch before/within worker drain,
   so the cycle proceeds instead of refusing. Reuse the committed-sync trick:
   once committed, the checkout is clean until the CLI drifts again.
2. **Deterministic detection helper**: `scripts/check-opsx-generated-dirt.sh`
   returns `ok:` when every status-visible dirty path is in the generated set,
   `non-opsx:` otherwise, so the decision is a falsifiable exit code, not prose
   judgment by the agent.
3. **Image-side hygiene**: keep the openspec CLI pinned/versioned in the forge
   image and regenerate into the tracked tree only on explicit operator
   invocation (or gate generation on the image build rather than every launch).
   Loses cadence alignment; lower priority — committing the drift is sufficient
   and keeps skills versioned.

Verifiable closure (order 540 exit criteria):

- litmus/CI: materialize a checkout whose only dirt is a simulated newer
  openspec CLI's regeneration of the 22 paths, run full meta-orchestration, and
  assert (a) the cycle does NOT refuse, (b) a `chore(opsx):` sync commit lands on
  the canonical branch local+remote, and (c) the dirty-start fixture with any
  non-opsx path still fails closed byte-identically.
- the existing dirty-tree safety litmus (order 489 child) stays green.

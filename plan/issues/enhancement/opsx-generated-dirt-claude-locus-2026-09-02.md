# enhancement: the opsx dirty-start detector knew only the .opencode locus, so every Claude-launched forge refused its cycle

- **Date**: 2026-09-02
- **Classification**: enhancement (boundary-noise; in-forge cycles)
- **Status**: fixed
- **Order**: 964-fwvh
- **Discovered by**: forge meta-orchestration cycle 2026-09-02T20:30Z (macuahuitl-tillandsias-forge)
- **Related**: plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540)

## What happened

Start Of Cycle found 22 dirty tracked paths, all of them openspec CLI
command/skill artifacts under `.claude/`:

- `.claude/commands/opsx/{apply,archive,bulk-archive,continue,explore,ff,new,onboard,propose,sync,verify}.md` (11)
- `.claude/skills/openspec-{apply-change,archive-change,bulk-archive-change,continue-change,explore,ff-change,new-change,onboard,propose,sync-specs,verify-change}/SKILL.md` (11)

`scripts/check-opsx-generated-dirt.sh` returned `non-opsx:` on all 22 and the
cycle refused with `blocked: dirty-start-worktree` before doing any work.

The verdict was correct for the code as written and wrong about the world. The
order-540 generated set is anchored to `.opencode/`. The openspec CLI writes
its templates once per agent harness it detects, so an OpenCode-launched forge
gets `.opencode/` and a Claude-Code-launched forge gets the identical 22
artifacts under `.claude/`, with the CLI's Claude layout (`commands/opsx/<verb>.md`
nested, rather than a flattened `opsx-<verb>.md`).

## Why this is order 540's ruling, not a new question

The 2026-07-31 operator decision is explicit and already covers this dirt:
"The opsx/openspec skill update is INTENDED and committable; it is versioned
project content, not scratch. The operator directed that this scenario must NOT
block a meta-orchestration cycle." The detector simply could not see the locus
the dirt arrived in.

Confirmed generated rather than authored before acting on it: `.claude/` is
byte-identical between `main` and `origin/linux-next`, so the content was
produced locally at launch and matched no committed state on any branch.

## The trap worth naming

Order 540's own text says "the checker is a falsifiable machine decision; do not
substitute prose judgment for it" — which is right, and which is exactly why the
fix is to widen the checker rather than to reason around its verdict. An agent
that talks itself past a `non-opsx:` verdict has disarmed the dirty-start
refusal for every genuinely dirty tree as well.

## Fix (landed 80335e60e, on trunk)

Widened the generated set to both harness loci and pinned it with three new
fixture branches: 1b (`.claude` only -> `ok:opsx-only`), 1c (both loci dirty at
once -> `ok:opsx-only`), 1d (real dirt alongside `.claude` dirt -> still
`non-opsx:`, rc=3, so the wider set does not weaken the refusal). 7/7 branches
pass.

## Residual

The set is still a hardcoded path list, so a THIRD harness locus repeats this
exactly. The generator is the openspec CLI, which knows the loci it writes; a
detector that asked the CLI (or matched a shape rather than a literal list)
would not need a third edit. Not done here — it is a larger change than the
unblock warranted, and worth deciding deliberately rather than in a preflight.

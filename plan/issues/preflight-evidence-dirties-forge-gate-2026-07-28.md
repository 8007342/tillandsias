# Preflight evidence regeneration dirties the post-build forge gate's worktree

- **Class**: optimization/ (release-cycle velocity; guard interplay, not a product defect)
- **Found**: 2026-07-28T00:22Z, v0.4.260728.1 release preflight on mutable Linux
- **Filed by**: linux-mutable-metaorch-20260727

## What happened

`scripts/release-preflight-local.sh` → `scripts/local-ci.sh` regenerates
evidence artifacts in the shared checkout (centicolon dashboards under
`docs/convergence/`, `TRACES.md` + 52 `openspec/specs/*/TRACES.md` indexes),
and only afterwards runs the post-build litmus phase. That phase includes
`litmus:opencode-prompt-e2e-shape`, which launches a REAL forge running
`/meta-orchestration` in full mode. The in-forge cycle's dirty-start guard
then — **correctly** — refused the cycle (`blocked: dirty-start-worktree`,
startup boundary verified byte-identical, clean exit, no commit), so the
litmus's STEP 4 "local HEAD advanced" expectation failed and the whole
preflight reported FAIL.

Every component behaved as specified; the composition is self-defeating:
the launcher dirties the very worktree whose cleanliness the launched
guard enforces. Evidence: `/tmp/opencode-e2e-forge.log` (agent handoff:
"commit or discard the existing trace-generation changes, then rerun"),
`/tmp/litmus-post-build.log` STEP 4 FAIL at HEAD 596b6bc8.

## Resolution this cycle

Generated evidence was committed (b3677fb3) per RELEASING.md step 4 and the
gate re-run. This recurrence class is adjacent to orders 489/490 (build
regeneration contaminating e2e state) but is a distinct composition bug in
local-ci phase ordering.

## Reduction (verifiable constraint)

Smallest fix, one of:
1. local-ci commits (or snapshots to `target/`) evidence artifacts BEFORE
   entering the post-build litmus phase, or
2. `scripts/litmus-opencode-e2e-launch.sh` pre-checks `git status --porcelain`
   and, when dirty with ONLY known-generated paths (TRACES.md,
   docs/convergence/*), records mode=deferred and skips the launch with an
   explicit `ok: deferred (generated-dirt present)` marker instead of letting
   the forge cycle fail the gate, or
3. the dashboards/trace indexes route under `target/` like the order-489 fix
   did for local install dashboards (discard-over-repair bias says prefer
   this: the order-489 redirection already exists as prior art).

Constraint to pin: a litmus step asserting that after `scripts/local-ci.sh`
completes its generate phases, `git status --porcelain` names no path that
the post-build forge gate's dirty-start guard would refuse — i.e. the
preflight is self-clean by construction.

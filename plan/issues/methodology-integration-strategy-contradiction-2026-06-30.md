# Methodology: integration_strategy was backwards (rebase⨉merge), corrected

**Status:** `in_progress`
**Owner:** linux
**Date:** 2026-06-30
**Kind:** analysis + enhancement (methodology/skills)
**Found by:** a `/meta-orchestration` soundness-validation run (operator-requested)
**Trace:** `methodology/multi-host-development.yaml`, `skills/{advance-work-from-plan,merge-to-main-and-release,multihost-orchestration}`

## Finding

Order 133 (the fix for the duplicate-commit trunk breakage) added to
`pull_merge_cadence.integration_strategy`:

> "strictly rebase onto origin/<branch> before push; **cross-branch integration
> uses rebase, NOT git merge**, to avoid duplicate commit hashes"

A meta-orchestration validation run found this is **unsound and contradicts
every other authority**:

- `meta-orchestration` coordinator duty #2: "**Merge** eligible origin/windows-next
  and origin/osx-next work into linux-next."
- `merge-to-main-and-release`: `gh pr merge --merge` — "Use `--merge` (not
  `--squash`) … Preserve it."
- Actual history is all merges: `bf55712c "Merge origin/windows-next and
  origin/osx-next into linux-next"`, `1a941807 "Merge origin/main into linux-next"`,
  the PR merges.

And it is **self-defeating**: a published sibling branch's commits cannot be
rebased into the trunk without cherry-picking them to NEW hashes — which RE-CREATES
the exact duplicate-hash problem (`cb9def48 -> 6dbca259`) order 133 set out to
prevent. The original duplication came from a rebased/cherry-picked copy of an
already-published commit being merged in alongside the original.

## Correct model (applied)

- **SAME-branch catch-up** (own un-pushed commits vs `origin/<same-branch>`):
  rebase the local commits, run the Integration Verification Gate, push. Rewrites
  only un-published hashes → cannot duplicate on the trunk.
- **CROSS-branch integration** (sibling→trunk, main→branch): **merge-only**.
  Merges preserve hashes so git dedupes already-present commits via ancestry.
  **Never rebase/cherry-pick published commits across branches.**

`methodology/multi-host-development.yaml` `integration_strategy` corrected to state
this explicitly. The Integration Verification Gate (advance-work-from-plan §6,
markers + YAML + build) remains the sound safety net — it catches residual
breakage regardless of strategy.

## Remaining reconciliation (the "complete" half)

The strategy is now correct in ONE place; make it consistent everywhere a future
agent might read:

1. `skills/advance-work-from-plan` §6 — the gate's `git rebase origin/<active-branch>`
   is correct ONLY for the same-branch case; add a one-line note that cross-branch
   sibling integration is merge-only (point to the methodology).
2. `skills/multihost-orchestration` — make its sibling-integration step say
   `git merge` explicitly and cite the strategy.
3. Verifiable closure: `litmus:integration-strategy-consistency` — grep the
   methodology + the three skills and fail if any says "rebase" for cross-branch
   sibling/main integration, or if the merge skills drift to rebase/squash.

## Why this matters (soundness of the convergence work)

Order 133 fixed the SYMPTOM detector (the gate) correctly but prescribed the wrong
git operation. An agent literally following the old text would cherry-pick sibling
work and reintroduce duplicate hashes — the loop would diverge, not converge. This
finding is the validation run doing its job: the process is now sound on this axis
once the reconciliation closes.

## Related

- `plan/issues/methodology-concurrent-integration-duplication-2026-06-28.md` (order 133)
- `plan/issues/agent-concurrency-collisions-2026-06-20.md`

# optimization: forge lane self-dirties `.opencode/package-lock.json` in the ephemeral clone

- Date: 2026-07-16
- Class: optimization (boundary-noise; in-forge cycles)
- Filed by: macos-Tlatoanis-MacBook-Air-fable5-20260716T0824Z
- Evidence: in-forge smoke run 20260716T0827Z (plan/issues/macos-inforge-smoke-pass-2026-07-16.md) — `git status` inside the freshly materialized clone showed `M .opencode/package-lock.json` before the agent did anything.

## Why this matters

Every in-forge meta-orchestration cycle snapshots a startup boundary; a
lane that dirties its own checkout during materialization makes every
boundary start dirty, which (a) is noise the agent must classify each
run, and (b) desensitizes agents to real pre-existing dirt — the exact
failure the dirty-start refusal exists to catch. On strict dirty-start
policy it would refuse EVERY forge cycle.

## Likely mechanism

OpenCode bootstrap in the lane runs an install against `.opencode/`
(package-lock regenerated/reformatted by the in-image npm version) after
the clone. The lockfile is tracked, so the rewrite shows as a modification.

## Reduction candidates (owner: linux forge-image seam)

1. Run the OpenCode install against a container-local copy (e.g.
   `~/.opencode-runtime`) instead of the tracked project dir; or
2. `git update-index --skip-worktree .opencode/package-lock.json` in the
   lane after materialization (ephemeral clone, safe); or
3. Pin the in-image npm to the version that produced the committed lock.

Verifiable closure: in-forge `git status --porcelain` is EMPTY immediately
after materialization, asserted by a step in the forge onboarding litmus.

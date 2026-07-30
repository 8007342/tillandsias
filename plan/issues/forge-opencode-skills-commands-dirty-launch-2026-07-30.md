# optimization: forge launch dirties `.opencode/commands/opsx-*.md` and `.opencode/skills/openspec-*/SKILL.md`

- Date: 2026-07-30
- Class: optimization (boundary-noise; in-forge cycles)
- Filed by: forge container (meta-orchestration cycle 2026-07-30)
- Evidence: Every forge launch leaves 22 tracked files modified under `.opencode/commands/` and `.opencode/skills/openspec-*/` — OpenCode's own install/bootstrap regenerates these skill and command descriptors. `git status --porcelain` is never clean inside a fresh forge.

## Why this matters

Every meta-orchestration cycle snapshots a startup boundary; `git status` is always dirty, which activates the dirty-start preflight refusal every time (a) even though the dirt is expected and harmless, and (b) desensitizes agents to real pre-existing dirt. This is the exact same class as `plan/issues/forge-lane-selfdirty-opencode-lockfile-2026-07-16.md` (`.opencode/package-lock.json`).

## Reduction candidate

Apply `git update-index --skip-worktree` to these path patterns in the forge entrypoint after materialization:

```
.opencode/commands/opsx-*.md
.opencode/skills/openspec-*/SKILL.md
```

This is a ZERO-TOKEN mechanical operation — a `find` + `git update-index --skip-worktree` loop in the forge entrypoint shell script. No agent awareness, no rules, no clever wording. Runtime enforcement only: `--skip-worktree` hides the local modifications from `git status`/`git diff` without affecting the committed content or future commits of these files.

See the sibling fix for `package-lock.json` in `forge-lane-selfdirty-opencode-lockfile-2026-07-16.md` (reduction candidate 2).

## Verifiable closure

In-forge `git status --porcelain` is EMPTY immediately after materialization, asserted by a step in the forge onboarding litmus glob. All 22 paths are `--skip-worktree`'d.

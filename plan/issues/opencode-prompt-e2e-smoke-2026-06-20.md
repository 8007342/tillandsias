# OpenCode-Prompt E2E Smoke — 2026-06-20

**Filed:** 2026-06-20T20:30Z
**Origin:** Operator request after `tillandsias . --opencode --prompt "..."` run
**Trace:** `spec:forge-offline`, `spec:e2e-smoke`, `spec:agent-cheatsheets`

## Goal

Make this invocation a first-class, verifiable e2e smoke case:

```bash
tillandsias . --opencode --prompt "Use the ./skills/meta-orchestration skill and push your progress and findings."
```

The smoke must verify:
1. The forge starts, OpenCode is launched with the prompt
2. The agent runs the meta-orchestration skill (reads plan, claims work, implements)
3. **The agent commits findings and pushes to the remote branch** (currently blocked — see order 66)
4. The push lands on `origin` and is verifiable from the host

## Current State

The invocation runs and the agent does useful work, but:
- Push is blocked (no credential channel — tracked in order 66)
- There is no post-run assertion that the findings reached the remote
- The e2e result is "agent ran and committed locally" — not "findings in plan"

## Deliverable

A litmus test `litmus:opencode-prompt-e2e-shape` that verifies:

```
tillandsias . --opencode --prompt "..." runs to completion
  → forge_exit=0
  → git log shows at least 1 new commit since smoke start
  → git push origin <branch> succeeds
  → remote branch HEAD advanced (verify via GitHub API or git ls-remote)
  → loop_status.md has a new cycle entry
```

## Dependency

Requires `forge-push/wire-git-remote` (order 66) to be resolved first so the push
path inside the forge is functional.

## Action Items

- `opencode-prompt-e2e/litmus`: write `opencode/litmus-opencode-prompt-e2e-shape.yaml`
  verifying the structural output (exit, new commit, new loop_status entry)
- `opencode-prompt-e2e/push-assert`: extend the smoke to assert remote branch advanced
  (requires order 66 forge push channel)
- `opencode-prompt-e2e/findings-reduce`: ensure the prompt instructs the agent to file
  findings to `plan/issues/` and reduce them to `plan/index.yaml` before pushing, so
  the run is self-contained and useful even from a cold forge

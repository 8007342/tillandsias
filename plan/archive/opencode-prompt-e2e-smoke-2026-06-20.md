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

## Action Items (completed 2026-06-21)

- ✅ `opencode-prompt-e2e/litmus`: created `openspec/litmus-tests/litmus-opencode-prompt-e2e-shape.yaml`
  verifying forge_exit=0, new commit, loop_status change, and remote HEAD advance.
  Registered in `openspec/litmus-bindings.yaml` under `spec_id: meta-orchestration`.
- ✅ `opencode-prompt-e2e/push-assert`: included as steps 2 and 6 of the litmus test
  (pre-smoke remote HEAD record + post-smoke remote HEAD advance check).
  Order 66 (forge-push-credential-channel) completed.
- ✅ `opencode-prompt-e2e/findings-reduce`: verified that the meta-orchestration skill
  already has a Reduction Engine section requiring filing and reduction before push.
  No skill edit needed.

# Full meta-orchestration can exit zero after losing its local commit

Date: 2026-08-05 (America/Los_Angeles)
Status: ready
Plan: `meta-orchestration-full-mode-exit-attestation-gap` (order 614-2gqx)
Release: v0.5

## Live reproduction

After a successful build/install, destructive Podman reset, and cold init, run
`20260806T085959Z` launched the installed product directly with the bare full
prompt:

```text
TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode \
  --prompt 'Use the /meta-orchestration skill'
```

The in-forge agent passed startup guards and used the expert MCP tools. It
created local commit `4a1410a2` for generated OpenSpec sync changes, then
reproduced order 600-c266 and stopped during implementation analysis. It never
ran the final worktree-boundary verification, never wrote a cycle result, and
never pushed. Container teardown discarded the clone and commit. Nevertheless,
OpenCode and the outer Tillandsias launcher both returned zero; `origin/linux-next`
remained at the pre-launch commit.

This is not a transport failure: the agent was alive, queried experts, read
files, and committed. It is a missing terminal attestation. The full-mode
skill's prose already forbids local-only commits, but a caller cannot distinguish
contract completion from a provider ending normally between tool calls.

## Deduplication

- Order 286 covers rate limiting and requires `MO-SMOKE` only in smoke mode.
- Order 404 covers adding Codex launcher/verdict parity to the existing smoke
  surface.
- Order 265 covers positive liveness while a forge is running.

None requires a machine-verifiable **full-mode** terminal marker emitted only
after boundary verification and remote persistence. This packet owns that gap;
the observed fragment-only append failure remains order 600-c266.

## Exit contract

- Define a full-mode terminal marker that includes the completed/blocked
  disposition and the final commit/remote head. It may be emitted only after
  the startup-boundary guard and the skill's commit/push obligations pass.
- Product E2E launchers reject process exit zero when that marker is absent,
  malformed, claims a different remote head, or follows an unpushed local
  commit.
- A fixture reproduces a provider ending after a local commit and proves the
  outer gate fails instead of discarding work as green.
- Smoke mode retains its existing `MO-SMOKE: PASS|FAIL` grammar and rate limit;
  full-mode attestation does not convert routine smoke runs into full cycles.
- The dated smoke report records both transport exit and skill-contract verdict
  as separate fields.

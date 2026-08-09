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

## Resolution (order 614-2gqx, implemented 2026-08-09)

Closed by the full-mode terminal attestation gate:

- **Marker grammar** (`skills/meta-orchestration/SKILL.md`, "Full-Mode Terminal
  Attestation"): a full cycle's FINAL output line MUST be
  `MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>`, emitted only
  after boundary verification, `./build.sh --check`, commit, and push. Smoke
  mode keeps its `MO-SMOKE:` grammar and the shared 4h rate limit unchanged.
- **Validator** (`scripts/mo-full-attest.sh`): parses the marker, enforces
  `LOCAL_SHA == REMOTE_SHA` (no unpushed local commit claim), matches the
  branch, and waits (bounded) for `git ls-remote` to converge on the claimed
  remote head — so a normal provider exit between tool calls can no longer
  return green. Exit 1 = marker missing/malformed/inconsistent, exit 2 =
  valid marker whose remote head never converged.
- **Launcher wiring** (`scripts/litmus-opencode-e2e-launch.sh`): full-mode
  runs that exit zero without a valid, converging marker now return
  `FORGE_EXIT=127/128` with the reason — mirroring the existing smoke-mode
  `126` gate.
- **Hermetic fixture** (`scripts/test-mo-full-attest.sh` →
  `scripts/mo-full-attest.sh fixture`): reproduces the early-provider-exit-
  after-local-commit breach shape plus malformed, unpushed-commit,
  branch-mismatch, and relay-lost scenarios against a fake remote probe, and a
  clean pass. Runs as the first critical-path step of
  `litmus:opencode-prompt-e2e-shape`.

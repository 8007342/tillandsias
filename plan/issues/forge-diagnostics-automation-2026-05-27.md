# Forge Diagnostics Automation — 2026-05-27

## Status

Active. This issue is the coordination record for the forge diagnostics
automation wave, running alongside platform-branch thin-wrapper work on
linux-next, windows-next, and osx-next.

## Host Identity

- host_id: linux-tlatoani-fedora
- platform: linux
- branch: linux-next
- agent_id: pickie (OpenCode big-pickle)
- lease_id: forge-diagnostics-automation-2026-05-27

## Observed Remote Heads (2026-05-27)

| Branch | Commit |
|---|---|
| `main` | e22a6853 |
| `linux-next` | 1a25c745 |
| `windows-next` | 1aebb284 |
| `osx-next` | deba10d8 |

## Context

The FORGE (Tillandsias Podman container bundling OpenCode/Claude/Codex) has 12
active specs with ~30-50% litmus-test coverage. Many requirements are validated
only by static shell-syntax checks or `grep`-for-trace — not by actual in-forge
agent execution. Existing E2E litmus tests (podman-idiomatic, browser isolation,
tray network bootstrap) launch real forge containers but never ask the agent
inside to self-report its capabilities.

This automation wave introduces a non-interfering diagnostics loop:

```
tillandsias . --opencode --diagnostics --prompt "<prompt>"
    → stdout → target/forge-diagnostics/diagnostics_$(ts).log
    → distilled → plan/diagnostics/YYYY-MM-DD-summary.md (pushed)
    → agents consume summaries → update specs/litmus → prompt evolves
```

The diagnostics loop is NOT part of `--ci-full`. It is an independent
orchestration that runs alongside E2E builds and enriches the convergence
record without blocking development of the linux headless, windows tray, or
macos tray thin wrappers.

## Deliverables

1. **`plan/diagnostics/forge-diagnostics-prompt.txt`** — Evolving hybrid prompt that asks
   the in-forge agent to self-report capabilities in structured (JSON) format.
   Base items cover core forge capabilities; spec-derived items are added as
   coverage gaps are identified.

2. **Diagnostics litmus test** (`phase: post-build`, `size: e2e`) — wraps the
   `tillandsias --opencode --diagnostics --prompt "..."` invocation so it can
   run as part of the existing litmus framework. The litmus test file specifies
   gating_points against the expected structured output.

3. **`openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`** — the actual
   litmus test that invokes the diagnostics prompt inside a live forge and
   validates the structured response.

4. **`plan/diagnostics/`** — Durable directory for distilled diagnostics
   summaries. Each summary captures the session, key findings, regressions
   vs. the previous run, and recommended next actions.

5. **`scripts/distill-forge-diagnostics.sh`** — Post-processing script that
   reads raw diagnostics logs, extracts structured results, appends to the
   durability trail in `plan/diagnostics/`, and emits a brief JSON summary.

## Methodology Gap — Request for Orchestrator

The current litmus methodology (`methodology/litmus.yaml`) has no concept of
"prompt the in-forge agent and evaluate its response as a test signal." All
existing litmus tests are shell commands running on the host or inside the
container — none ask the LLM agent itself to produce diagnostic output.

**Request to the Orchestrator**: Update `methodology/litmus.yaml` (or create a
companion in `methodology/forge-diagnostics.yaml`) to:

1. **Define a new litmus signal type**: `agent_diagnostic` — where the
   critical path steps include a prompt sent to the forge agent and the
   gating points include structured-response patterns in the agent's output.

2. **Composability rule**: E2E litmus tests that already launch a forge
   (podman-idiomatic-enclave-network, browser-isolation-e2e, etc.) MAY
   append forge-diagnostics sub-steps to their critical_path so every
   expensive forge launch doubles as a completeness probe. Example:
   a network-isolation E2E test runs `curl https://evil.com` AND asks
   the forge agent "can you reach inference?" — reusing the same
   container lifetime.

3. **Output coupling**: When an E2E litmus includes forge-diagnostics steps,
   the agent response text SHALL be written to
   `target/forge-diagnostics/diagnostics_$(date -u +%FT%H%M%SZ).log`
   alongside the test's normal stdout, so the summarization pipeline can
   consume it regardless of which test triggered it.

4. **Non-blocking annex**: forge-diagnostics steps MUST NOT change the
   parent litmus test's pass/fail verdict. A diagnostics probe that fails
   (e.g., the agent could not run `curl`) is a forge-completeness signal,
   not an E2E regression. The parent test may pass while diagnostics are
   collected; the diagnostics are summarized separately.

5. **Cross-test deduplication**: If multiple E2E tests in the same CI run
   include forge-diagnostics steps, only the first invocation runs the full
   diagnostics prompt; subsequent invocations append a short checksum-based
   skip reference to avoid repeating expensive agent work.

The Orchestrator should produce a methodology PR or plan issue with the
proposed spec changes, then assign it back to this agent or any other agent
that picks up forge work.

## Handoff Note

Cold-start agents should read this issue, then:

```bash
cat plan/diagnostics/forge-diagnostics-prompt.txt
cat plan/diagnostics/forge-completeness-baseline-2026-05-27.md
cat openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml
cat methodology/litmus.yaml   # after orchestrator updates
```

Key files:
- `plan/diagnostics/forge-diagnostics-prompt.txt` — the evolving diagnostic prompt
- `plan/diagnostics/` — durability trail for forge completeness over time
- `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml` — the diagnostics litmus test
- `target/forge-diagnostics/` — raw diagnostic logs (ephemeral, not committed)

Next action: await orchestrator methodology update, then wire the diagnostics
litmus test into the E2E rotation.

## Checkpoint

This file was committed and pushed to `origin/linux-next` at the end of the
forge-diagnostics-automation session. The diagnostics prompt and litmus test
are in place; the methodology gap requires orchestrator input.

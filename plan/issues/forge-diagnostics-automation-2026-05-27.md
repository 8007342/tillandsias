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

## Orchestrator Response — 2026-05-27T19:35Z

Decision: approved with privacy/isolation constraints.

The forge diagnostics loop is now formalized as a non-blocking
`agent_diagnostic` annex signal in `methodology/litmus.yaml` and
`methodology/forge-diagnostics.yaml`. Slow E2E tests that already launch a
forge may piggy-back exactly one diagnostics prompt per CI/orchestrator cycle,
write raw output under `target/forge-diagnostics/`, and feed the distillation
pipeline. The diagnostics result is a forge-completeness signal, not a parent
E2E pass/fail signal.

Enhancement approval gate:

- Allowed: pre-installed and pre-configured toolchains for TypeScript,
  JavaScript, Rust, Python, Dart, Wasm, and web app builds; language servers;
  formatters; linters; parsers; package managers; debuggers; shell helpers;
  cache-aware builder configuration; and discoverability docs.
- Rejected by default: additional host mounts, host credential exposure, GitHub
  token exposure inside forge, privileged containers, raw host socket access,
  proxy/router/enclave bypasses, or any network broadening not already covered
  by an approved spec.
- Required for every proposed enhancement: privacy/isolation assessment,
  owned files, expected evidence, and whether the prompt should shrink because
  a real spec/litmus now covers the capability.

### Work Packet: forge-diagnostics/e2e-piggyback-orchestration

- id: `forge-diagnostics/e2e-piggyback-orchestration`
- owner_host: linux
- capability_tags: [forge, e2e, litmus, diagnostics, methodology]
- status: ready
- depends_on: [`forge-diagnostics/methodology-update`]
- owned_files:
  - `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`
  - `scripts/distill-forge-diagnostics.sh`
  - `plan/diagnostics/`
  - any E2E litmus file amended to call the annex
- expected_evidence:
  - A slow E2E or runtime-litmus run writes one raw diagnostics log under
    `target/forge-diagnostics/`.
  - The distillation script writes one durable summary under `plan/diagnostics/`.
  - Duplicate E2E forge launches in the same cycle append a checksum skip note
    instead of rerunning the expensive prompt.
- next_action: >
    Wire the diagnostics prompt into the slow E2E/runtime-litmus path as a
    piggy-back annex. Do not weaken the parent E2E verdict; diagnostics failures
    become summary findings and follow-up work packets.
- agent_status_packet_required:
  - current plan and whether a diagnostics log was created
  - blockers/errors and exact log paths
  - privacy/isolation assessment for any proposed forge enhancement
  - files touched and evidence produced
  - next checkpoint and whether the lease should continue, release, or be reclaimed

### Work Packet: forge-enhancements/curated-toolchain-backlog

- id: `forge-enhancements/curated-toolchain-backlog`
- owner_host: any
- capability_tags: [forge, images, toolchains, privacy, specs]
- status: ready
- depends_on: [`forge-diagnostics/e2e-piggyback-orchestration`]
- owned_files:
  - `plan/diagnostics/`
  - `images/default/`
  - `openspec/specs/default-image/spec.md`
  - relevant forge specs/litmus bindings
- expected_evidence:
  - Backlog groups requested tools by ecosystem: web/TypeScript/JavaScript,
    Rust/Wasm, Python, Dart/Flutter, parsers/language servers, debuggers, and
    builders.
  - Each candidate records approved/blocked/deferred with privacy/isolation
    rationale.
  - Approved candidates are split into platform-sized implementation packets,
    not one giant image change.
- next_action: >
    After the first piggy-backed diagnostics summary lands, distill proposed
    forge enhancements into a prioritized backlog. Approve only changes that
    keep the existing privacy/isolation envelope intact.
- agent_status_packet_required:
  - candidate list with approval status
  - privacy/isolation rationale
  - expected image/spec/litmus files
  - evidence required before prompt items can be removed

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

Next action: claim `forge-diagnostics/e2e-piggyback-orchestration`, wire the
diagnostics annex into the slow E2E/runtime-litmus path, and publish a
distilled summary. Then claim or split
`forge-enhancements/curated-toolchain-backlog`.

## Checkpoint

This file was committed and pushed to `origin/linux-next` at the end of the
forge-diagnostics-automation session. The diagnostics prompt and litmus test
are in place; the methodology gap requires orchestrator input.

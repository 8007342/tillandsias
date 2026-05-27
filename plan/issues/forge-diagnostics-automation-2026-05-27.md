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
| `main` | fa746f03 |
| `linux-next` | 891bb757 before this coordination commit |
| `windows-next` | 1e20d6d0 |
| `osx-next` | f8778350 |

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

## agent_status_packet — forge-diagnostics/e2e-piggyback-orchestration — 2026-05-27T19:40Z

- host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next
- packet: `forge-diagnostics/e2e-piggyback-orchestration` — CLAIMED + slice 1
  shipped (`a87afce1`). Dependency `methodology-update` confirmed landed
  (methodology/forge-diagnostics.yaml + methodology/litmus.yaml present).
- current plan / diagnostics log: **no raw diagnostics log captured yet** — a
  real capture requires an installed `tillandsias` + a live forge during a slow
  E2E/runtime-litmus run; this slice built the non-blocking annex + dedup
  plumbing and wired the standalone litmus through it. The dedup path was
  self-tested without a forge (reset → seed → skip-with-note → status → reset).
- files touched: `scripts/forge-diagnostics-annex.sh` (new, non-blocking annex
  with checksum dedup, --reset/--status), `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`
  (two double-launch steps → one `--reset` + one annex call).
- evidence: dedup self-test output (skip note → cycle-skips.log); annex `bash -n`
  clean; litmus runner parses the amended spec.
- privacy/isolation assessment: this slice proposes NO forge enhancement; it is
  pure orchestration (capture + dedup + distill). No new mounts, creds, sockets,
  or network changes. Envelope intact.
- blockers/errors: NONE. (The earlier shared-CI rustfmt drift in macOS-owned
  files is already RESOLVED — macOS fix `4935404a` is in linux-next;
  `cargo fmt --all -- --check` clean as of `a87afce1`.)
- next checkpoint: amend the other forge-launching E2E litmus files to call the
  annex WITHOUT --reset (so the first captures, rest skip in-cycle); produce the
  first real distilled summary on the next runtime-litmus that has a live forge;
  then claim/split `forge-enhancements/curated-toolchain-backlog`.
- lease: CONTINUE (more slices in this packet).

## agent_status_packet — work-loop slice 2026-05-27T20:30Z — container-start-health

- shipped `b9a36388`: deterministic host-side container-start verification.
  Extracted `format_launch_event()` (unit-pinned the idiomatic layer's
  `event:container_launch stage=… state=… container=…` wire shape, 2 tests)
  + new `openspec/litmus-tests/litmus-container-start-health.yaml` asserting
  every launched container reaches `state=running`, ZERO `state=failed`,
  forge specifically running, and that the stream exists (proves no
  raw-podman bypass).
- Also this session (out-of-loop, user-reported): fixed the Vault rootless
  bridge-network bug (`7ff9532c`) — `--init` was failing at vault bring-up.
- tests: tillandsias-podman 105/105.
- next: (a) make `--diagnostics "<prompt>"` reliably surface the in-forge
  agent capability JSON (needs a live forge to verify — defer to a runtime
  litmus); (b) wire the annex (no --reset) into other forge-launching E2E
  litmus so container-start diagnostics piggyback; then headless spec gaps
  (CloudRefreshRequest / VmStatusRequest / EnumerateLocalProjects real
  handlers).
- lease: CONTINUE.

## coordinator observation — 2026-05-27T21:16Z

- Runtime-litmus `20260527T211507Z-b463cb53-cca9da4a-b463cb53` stopped at the
  `rust-formatting` build gate before installed `tillandsias --debug --init`
  or forge diagnostics could run.
- No raw `target/forge-diagnostics/` output should be expected from this run.
  Keep the next action from the 20:30Z packet: wire another forge-launching E2E
  litmus through the annex without weakening its parent verdict.

## coordinator observation — 2026-05-27T23:28Z

- Runtime-litmus `20260527T231258Z-b06a5997-1e20d6d0-b06a5997` reached
  `./build.sh --ci-full --install` but failed at `Disk quota exceeded` before
  installed `tillandsias --debug --init` or the diagnostics prompt could run.
  No raw `target/forge-diagnostics/` output should be expected from that run.
- Replacement full installed runtime-litmus
  `20260527T231940Z-b06a5997-1e20d6d0-b06a5997` ran on the pre-rebase
  `b06a5997` tree after scratch worktree cleanup. Build/install and
  `tillandsias --debug --init` passed, then
  `tillandsias . --opencode --diagnostics --prompt ...` failed with a
  nested-runtime panic at
  `crates/tillandsias-headless/src/vault_bootstrap.rs:205`.
- The diagnostics annex created two zero-byte raw logs. The latest empty log
  was distilled to
  `plan/diagnostics/diagnostics_20260527T232335Z-summary.md`.
- Push-time rebase absorbed `origin/linux-next` `891bb757`, so any diagnostics
  output from this run is useful but does not validate the latest diagnostics
  timestamp change.
- Next action: fix or assign the nested-runtime panic, then start a fresh
  runtime for current `origin/linux-next` and distill the first non-empty raw
  diagnostics log.
- No forge enhancement is approved by this observation. The lease-overlap note
  below still applies; coordinate before taking the next forge-diagnostics
  owned-file slice.

## agent_status_packet — work-loop slice 2026-05-27T21:35Z — clever-prompt actionable analysis

- host_id: linux-tlatoani-fedora · agent: claude-opus (linux WORK loop, cron e3a4f695)
- shipped `1f89f4bd`: aligned prompt ↔ distiller ↔ litmus to the methodology
  response_shape's actionable arrays (missing_tools / proposed_enhancements /
  isolation_or_privacy_risks). The "clever prompt" now instructs in-envelope
  analysis (hard privacy/isolation rule); the distiller surfaces an "Enhancement
  Candidates (→ curated-toolchain-backlog)" + "Isolation/Privacy Risks" section;
  the litmus structurally asserts the three arrays. Fixed a set -e grep-abort in
  distill. Verified via fixture (sections render; empty-risks doesn't abort) +
  litmus assertion compiles.
- evidence: fixture distill run (transient, not committed); no live forge needed.
- ⚠️ LEASE OVERLAP: this issue's header shows lease_id forge-diagnostics-automation
  -2026-05-27 / agent_id `pickie` (OpenCode big-pickle). I (claude-opus linux WORK
  loop) have been shipping diagnostics slices per the USER's direct linux-host
  directive; pushes have stayed conflict-free, but to avoid colliding with pickie
  I'm DONE touching forge-diagnostics owned_files for now. Coordinate before
  either of us takes the next forge-diagnostics slice.
- next (this loop, NON-overlapping): headless spec gaps — VmStatusRequest real
  lifecycle transitions, runtime-diagnostics-stream / observability-metrics spec
  audits. These are outside the forge-diagnostics packet scope.

# spec: forge-environment-discoverability

<!-- # freshness: auditor=linux-tlatoani-claude-20260807t021700z date=2026-08-07 verdict=updated scope=full re-read during 606-xu52/606-z389; added plan_next selector requirement+Test and the generic-project bootstrap quartet; retro-created Implementation Notes now outdated in part (the spec actively governs the EXPERTS surface) -->

## Status

active

## Overview

Define the runtime discovery interface for the forge container, allowing agents and developers to query the installed toolchains, available services, and available inference models. This spec keeps the forge self-documenting without assuming a richer command tree than the current scripts expose.

@trace spec:forge-environment-discoverability

## Requirements

### Requirement: Inventory CLI lists installed toolchains

The forge MUST provide a `tillandsias-inventory` command that outputs a structured list of all installed programming language toolchains and their versions.

#### Scenario: User queries installed languages
- **WHEN** a user runs `tillandsias-inventory` inside the forge
- **THEN** the command outputs a machine-readable list of installed toolchains with versions
- **AND** includes: Rust (+ cargo), Go, Python, Node.js, Java (Maven/Gradle), C/C++ (gcc/clang), Nix, etc.
- **AND** each entry includes the canonical version identifier (e.g., `rust: 1.75.0, rustc`)

#### Scenario: Verbose inventory with paths
- **WHEN** a user runs `tillandsias-inventory --json`
- **THEN** the output includes the path to each binary (e.g., `/usr/bin/rustc`, `/nix/store/.../python`)
- **AND** optional: last-updated date if applicable

### Requirement: Services CLI lists running containers and services

The forge MUST provide a `tillandsias-services` command that queries the enclave network and lists running containers with their network endpoints and roles.

#### Scenario: Agent discovers services
- **WHEN** a user runs `tillandsias-services` inside the forge
- **THEN** the command outputs a list of containers accessible via the enclave network
- **AND** includes: proxy (HTTP/HTTPS caching), git-service (git daemon + push), inference (ollama REST API), etc.
- **AND** each entry includes network endpoint (host:port or unix socket)

#### Scenario: Service discovery for inference
- **WHEN** an agent runs `tillandsias-services --json`
- **THEN** the command outputs the ollama API endpoint (e.g., `http://inference:11434`)
- **AND** a list of available models (output from `ollama list`)

### Requirement: Models CLI queries available LLM models

The forge MUST provide a `tillandsias-models` command that queries the inference service and lists available language models with their capabilities.

#### Scenario: Agent discovers model inventory
- **WHEN** a user runs `tillandsias-models` inside the forge
- **THEN** the command outputs models accessible via the inference container
- **AND** includes: baked models (T0: qwen2.5:0.5b, T1: llama3.2:3b) and any lazy-pulled models
- **AND** each entry includes model name, size, tier classification

#### Scenario: Models CLI stays machine-readable
- **WHEN** a user runs `tillandsias-models --json`
- **THEN** the output is machine-readable JSON
- **AND** includes tier classification (T0 = instant, T1 = fast, T2-T5 = larger/slower)

### Requirement: Welcome banner on terminal entry

The forge MUST display a welcome banner when a user opens an interactive terminal session. The banner SHOULD be brief and point to discovery commands.

#### Scenario: User enters maintenance terminal
- **WHEN** a user runs `tillandsias attach /path/to/project --terminal`
- **THEN** an interactive bash/zsh shell opens with a welcome banner
- **AND** the banner mentions key discovery commands: `tillandsias-inventory`, `tillandsias-services`, `tillandsias-models`
- **AND** the banner is non-intrusive (e.g., colorized, brief, not blocking)

### Requirement: Discovery commands are discoverable via `--help`

All discovery commands MUST support `--help` and provide usage examples.

#### Scenario: User discovers available commands
- **WHEN** a user runs `tillandsias-inventory --help`
- **THEN** the output includes the command purpose and `--json`
- **AND** includes example usage for the flat command shape

### Requirement: MCP host-services tool surface is organically discoverable

The forge MUST expose host-service tools (publish_local, service_status,
service_stop) via the MCP tool surface so that an agent can discover and
use them without out-of-band instructions. The config-overlay MCP entry,
the web-services instruction file, and the tray-side MCP handler MUST
all reference the same tool family.

#### Scenario: Agent discovers publish tools via tools/list
- **WHEN** an agent sends `tools/list` through the host-browser MCP server
- **THEN** the response includes `publish_local`, `service_status`, and `service_stop`
- **AND** the server identifies itself as `tillandsias-host-services`

#### Scenario: Config-overlay MCP entry points to the bridge
- **WHEN** the opencode config.json is inspected
- **THEN** the `host-browser` MCP entry command points to `mcp/host-browser.sh`
- **AND** the entry is enabled

#### Scenario: Web-services instruction documents the tool family
- **WHEN** the `web-services.md` instruction file is read
- **THEN** it documents `publish_local`, `service_status`, and `service_stop`
- **AND** it explains the safety model (project attribution from session, not request)

### Requirement: Plan expert preserves release constraints and dependency direction

@trace order:606-e2hg

The forge plan expert MUST expose deterministic release-aware and
dependency-direction-aware queries. An explicit desired-release constraint MUST
be matched exactly and MUST survive in structured output; it MUST NOT be treated
as optional natural-language decoration. Upstream prerequisites and downstream
consumers MUST remain separate query primitives.

#### Scenario: Agent filters the active release
- **WHEN** an agent queries plan work with `desired_release: v0.5`
- **THEN** every returned packet has exactly `desired_release: v0.5`
- **AND** the JSON projection includes both `desired_release` and `release_target`
- **AND** a known release with no rows after the other constraints returns an empty result

#### Scenario: Agent asks what blocks a milestone
- **WHEN** an agent asks `what blocks forge-local-experts-milestone`
- **THEN** the expert returns that milestone's own direct unsatisfied `depends_on` prerequisites
- **AND** completed, obsoleted, and archived prerequisites are omitted as satisfied
- **AND** downstream packets that depend on the milestone are not returned
- **AND** the existing downstream `blocked-by` and closure primitives retain their direction

#### Scenario: Unsupported constraints fail explicitly
- **WHEN** an agent supplies an unknown release, unknown argument, missing value, or invalid argument type
- **THEN** the CLI returns a typed non-zero usage error
- **AND** the forge-plan MCP surface returns JSON-RPC `-32602 Invalid params`
- **AND** neither surface silently executes a broader unconstrained query

### Requirement: Plan expert ranks claimable next work deterministically

@trace order:606-xu52

The plan expert MUST expose a `plan_next` selector returning at most FIVE
cited, release-aware, role-compatible, dependency-clear, unleased claimable
packets, ranked by the committed tuple (priority, release-targeted first,
order). The release MUST default from the folded `## ACTIVE RELEASE`
declaration; milestones and criteria holders MUST never be offered as claims;
an empty result MUST be the typed `unsupported: no claimable work` refusal.
The natural aliases are exactly `what's next?` and the
`what <release> work can I do on <role>?` family, and the rendered answer
MUST stay within the committed byte budget.

#### Scenario: Cold agent asks what's next
- **WHEN** an agent with a fresh context asks `what's next?`
- **THEN** at most five ready packets are returned in deterministic tuple order
- **AND** every row is cited to its winning source and carries a ranking reason and a concrete next action
- **AND** packets with unmet dependencies, live leases, claimed file scopes, incompatible roles, milestone kinds, or criteria-holder status are excluded

#### Scenario: No claimable work is a typed refusal
- **WHEN** the filters leave zero eligible packets
- **THEN** the answer is `unsupported: no claimable work ...` naming the release and role constraints
- **AND** no unscoped or widened query runs silently

### Requirement: Generic project expert bootstrap is zero-intervention

@trace order:606-z389

The forge MUST bootstrap a project expert surface for an ARBITRARY mounted
project without manual registration, configuration, or repository-type
knowledge from the caller. The canonical project location is resolved in
order: `TILLANDSIAS_PROJECT_PATH` when set; else
`/home/forge/src/${TILLANDSIAS_PROJECT}`; else the working directory. Git-ness
MUST be a detected, reported property — never a precondition. The Tillandsias
plan expert remains an additive specialization: its presence upgrades the
surface, its absence never degrades the generic contract below C2-C5 of the
design record.

#### Scenario: Fresh non-Tillandsias project gets a warmed surface
- **WHEN** a forge launches with `TILLANDSIAS_PROJECT_PATH` naming a project with no `crates/tillandsias-plan`
- **THEN** the generic discovery pass indexes the checkout without any manual step
- **AND** `project_answer` returns cited project type, structured status, discovered commands, and next actions
- **AND** the plan-expert state remains the honest `degraded(no-plan-crate)` without making the generic surface unavailable

#### Scenario: Non-git directory is a supported shape
- **WHEN** the project path is a readable directory that is not a git repository
- **THEN** discovery completes and reports a named not-a-git-repository property
- **AND** no bootstrap step fails or blocks on the absence of git metadata

### Requirement: Project index is ephemeral and rebuilt from the active checkout

@trace order:606-z389

The generic project index MUST live under the tmpfs experts state directory,
MUST be built at launch, MUST refresh on commit where a git hook path exists
and at every launch for all project shapes, and MUST die with the container.
No learned or discovered project state may persist across sessions, land on
persistent per-project volumes, or leak into images.

#### Scenario: Index dies with the container
- **WHEN** a forge shuts down and a new one launches on the same project
- **THEN** the new session's index is rebuilt from the freshly mounted checkout
- **AND** no stale discovery survives from the previous session

### Requirement: Generic expert readiness is machine-readable and never blocks launch

@trace order:606-z389

The generic engine MUST publish its own state line
`project-expert: ready | building(<n>s) | degraded(<reason>)` with a CLOSED
reason vocabulary (`no-project-path`, `unreadable-path`, `index-failed`,
`not-built`), parallel to and never mutating the pinned plan-expert grammar.
Harness launch and user prompts MUST NOT wait on discovery; overruns render
the same abandoned-build degradation the plan expert uses.

#### Scenario: Discovery failure is a named state, not a hang
- **WHEN** the project path is unreadable or discovery fails
- **THEN** the state renders `project-expert: degraded(<reason>)` from the closed vocabulary
- **AND** the harness session proceeds normally with the degraded state visible to agents

### Requirement: project_answer is one uniform cited surface with a deterministic fallback

@trace order:606-z389

A single `project_answer` surface MUST answer project questions in the
ratified envelope for every project shape, routing internally to the
specialized plan/methodology engines when present and to the generic index
otherwise — the caller never selects a project-specific tool. When local
inference is unavailable, the deterministic subset (type, status, commands,
layout, actions) MUST still answer from the index alone; everything else is
the typed refusal. Citations are deterministic-layer products in every
configuration.

#### Scenario: One question, any project
- **WHEN** an agent asks `what's next?` through `project_answer`
- **THEN** a Tillandsias-shaped project answers via plan_next and any other project answers from the generic index
- **AND** both answers are cited envelopes verifiable with `verify-answer`

#### Scenario: Inference outage keeps the deterministic subset
- **WHEN** no local inference endpoint is available
- **THEN** deterministic questions still answer with citations
- **AND** questions needing synthesis return `unsupported:` rather than an uncited guess

## Litmus Tests

### Test: tillandsias-inventory command completeness
- **Setup**: Launch forge container
- **Action**: Run `tillandsias-inventory --help` and `tillandsias-inventory --json`
- **Signal**: Output lists installed toolchains (rust, go, python, node, java, c/c++)
- **Pass**: Help mentions `--json`; JSON output is parseable and includes 6+ toolchains with versions
- **Fail**: Missing toolchains, malformed output, or version query fails

### Test: tillandsias-services enclave discovery
- **Setup**: Launch forge with proxy, git, inference services active
- **Action**: Run `tillandsias-services` inside forge
- **Signal**: Lists 3+ services with network endpoints
- **Pass**: proxy (http:3128), git-daemon (9418), inference (11434) all reachable; endpoints correct
- **Fail**: Services missing, unreachable, or wrong ports

### Test: tillandsias-models inference availability
- **Setup**: Launch inference container with T0/T1 models baked; optionally lazy-pull T2
- **Action**: Run `tillandsias-models` and `tillandsias-models --json`
- **Signal**: T0 (qwen2.5:0.5b), T1 (llama3.2:3b) always listed; T2+ shown if available
- **Pass**: Correct models listed by tier; JSON output is parseable
- **Fail**: Models missing or incorrect tier

### Test: Welcome banner on terminal entry
- **Setup**: Attach forge with `tillandsias attach /path/to/project --terminal`
- **Action**: Observe initial shell prompt
- **Signal**: Banner displayed before prompt
- **Pass**: Banner mentions discovery commands, is colorized, non-intrusive; doesn't block
- **Fail**: Banner missing, blocks input, or appears after other output

### Test: Help command consistency
- **Setup**: Run `tillandsias-inventory --help`, `tillandsias-services --help`, `tillandsias-models --help`
- **Action**: Compare output format and structure
- **Signal**: All help texts follow same template (usage, subcommands, examples)
- **Pass**: Consistent format across all commands; examples are runnable
- **Fail**: Inconsistent format, missing subcommands, or examples contain typos

### Test: Plan expert release and upstream query semantics
- **Setup**: Build the real `tillandsias-plan` binary and launch `forge-plan.sh` over stdio
- **Action**: Query v0.5 Linux work, query the experts milestone's blockers, and seed unknown release/argument constraints
- **Signal**: Structured release fields, exact release rows, direct unsatisfied prerequisites, and typed JSON-RPC errors
- **Pass**: No result leaks another release or reverses the dependency direction; every seeded invalid constraint is refused
- **Fail**: A constraint is ignored, a downstream consumer is returned as an upstream prerequisite, or the MCP wrapper reports invalid parameters as a successful tool result

### Test: Plan next deterministic selector
- **Setup**: Build the real `tillandsias-plan` binary; use the committed fixture corpus at `openspec/litmus-tests/groundtruth/fixtures/plan-next/` and the live ledger
- **Action**: Grade `expert-groundtruth-plan-next.yaml` against the fixture; call `plan_next` through `forge-plan.sh` with a valid role/limit, an over-cap limit, and an unknown argument
- **Signal**: Adjacency-ordered rows matching the committed ranking tuple, a five-row cap against six eligible packets, a typed no-work refusal, a verifiable served envelope, and JSON-RPC `-32602` on invalid constraints
- **Pass**: All fixture cases green; the served exact envelope verifies; every invalid constraint is a protocol error with one telemetry row per call
- **Fail**: Row order varies between runs, an excluded class (milestone, criteria holder, lease, claimed file scope, unmet dependency, foreign release, incompatible role) is offered as a claim, or the cap or refusal grammar breaks

## Implementation Notes

Originally created retroactively during the traces-audit refactor; since the
2026-08 EXPERTS wave (orders 606-e2hg, 606-xu52, 606-z389) this spec ACTIVELY
governs the forge expert surface: release/dependency query semantics, the
deterministic plan_next selector, and the generic-project bootstrap contract.
The design record for the generic contract is
`plan/issues/generic-project-expert-bootstrap-design-2026-08-07.md`.

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

```bash
git log --all --grep="forge-environment-discoverability" --oneline
git grep -n "@trace spec:forge-environment-discoverability"
```

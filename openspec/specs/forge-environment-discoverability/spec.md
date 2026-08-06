# spec: forge-environment-discoverability

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

## Implementation Notes

This spec is created retroactively as part of the traces-audit refactor. It may represent:
- An abandoned initiative that was never fully spec'd
- A feature whose spec was lost or mishandled
- A trace annotation that should have been corrected instead

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

```bash
git log --all --grep="forge-environment-discoverability" --oneline
git grep -n "@trace spec:forge-environment-discoverability"
```

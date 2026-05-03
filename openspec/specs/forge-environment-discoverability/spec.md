# spec: forge-environment-discoverability

## Status

active

## Overview

Define the runtime discovery interface for the forge container, allowing agents and developers to query the installed toolchains, available models, and environment capabilities. This spec ensures discoverable, self-documenting forge environments.

@trace spec:forge-environment-discoverability

## Requirements

### Requirement: Inventory CLI lists installed toolchains

The forge MUST provide a `tillandsias-inventory` command that outputs a structured list of all installed programming language toolchains and their versions.

#### Scenario: User queries installed languages
- **WHEN** a user runs `tillandsias-inventory languages` inside the forge
- **THEN** the command outputs a machine-readable list of installed toolchains with versions
- **AND** includes: Rust (+ cargo), Go, Python, Node.js, Java (Maven/Gradle), C/C++ (gcc/clang), Nix, etc.
- **AND** each entry includes the canonical version identifier (e.g., `rust: 1.75.0, rustc`)

#### Scenario: Verbose inventory with paths
- **WHEN** a user runs `tillandsias-inventory languages --verbose`
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
- **WHEN** an agent runs `tillandsias-services inference`
- **THEN** the command outputs the ollama API endpoint (e.g., `http://inference:11434`)
- **AND** a list of available models (output from `ollama list`)

### Requirement: Models CLI queries available LLM models

The forge MUST provide a `tillandsias-models` command that queries the inference service and lists available language models with their capabilities.

#### Scenario: Agent discovers model inventory
- **WHEN** a user runs `tillandsias-models` inside the forge
- **THEN** the command outputs models accessible via the inference container
- **AND** includes: baked models (T0: qwen2.5:0.5b, T1: llama3.2:3b) and any lazy-pulled models
- **AND** each entry includes model name, size, tier classification

#### Scenario: Model filtering by capability
- **WHEN** a user runs `tillandsias-models --coding`
- **THEN** the output is filtered to only show models optimized for code generation
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
- **THEN** the output includes subcommands (`languages`, `tools`, etc.) with brief descriptions
- **AND** includes example usage: `tillandsias-inventory languages --verbose`

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


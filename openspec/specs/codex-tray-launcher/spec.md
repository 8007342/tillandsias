# codex-tray-launcher Specification

@trace spec:codex-tray-launcher

## Status

active

## Requirements

### Requirement: Tray-launched Codex uses the forge entrypoint contract

The tray MUST launch Codex inside the forge container through the dedicated entrypoint so hot/cold environment setup, project paths, and agent instructions are applied consistently.

#### Scenario: Codex launch uses project workspace

- **WHEN** the tray starts Codex for a project
- **THEN** the process MUST run with the project workspace as its working directory
- **AND** the launch event MUST include enough metadata to diagnose entrypoint failure

## Sources of Truth

- `cheatsheets/runtime/codex-agent-entrypoints.md` - Codex entrypoint contract
- `cheatsheets/runtime/forge-hot-cold-split.md` - Forge environment setup
- `cheatsheets/runtime/tray-state-machine.md` - Tray action state handling


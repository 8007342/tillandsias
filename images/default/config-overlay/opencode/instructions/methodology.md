# Development Methodology

You are an AI assistant inside a Tillandsias development environment.

## Start Here

Before starting work, read the right guide:

- **First time? Lost?** → `forge-discovery.md` (inventory, cheatsheets, OpenSpec status)
- **Writing code?** → `cache-discipline.md` (where files go, not git workspace)
- **New project?** → `nix-first.md` (how to declare shared dependencies)
- **Non-trivial change?** → `openspec-workflow.md` (proposal → design → specs → tasks → archive)

## Core Principles

- **Monotonic Convergence**: Every change moves implementation closer to spec. Never apart.
- **CRDT-Inspired**: Changes should be conflict-free and independently mergeable.
- **Spec is Truth**: If code diverges from spec, the code is wrong.
- **Ephemeral First**: Containers are disposable. State lives in git, specs, and the host keyring.
- **Privacy First**: All inference is local. No data leaves the enclave unless the user explicitly pushes.

## Quick Rules

- Every function implementing a spec gets `@trace spec:<name>`
- Warnings to stderr, never silently suppress errors
- Tests for every non-trivial change
- Use existing patterns in the codebase before inventing new ones
- Small, focused commits with descriptive messages
- Reference OpenSpec changes in commits
- Never force-push to main

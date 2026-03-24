## Context

Tillandsias forge containers are ephemeral — created on demand, destroyed after use. But credentials must persist: a user authenticates with GitHub once, and that token should be available in every forge session without re-authentication. The challenge is making this transparent (users never see encryption mechanics) while keeping secrets safe from the AI agent running inside the container and from host-level exposure at rest.

## Goals / Non-Goals

**Goals:**
- Define the canonical filesystem layout for secrets storage
- Categorize secrets by scope (shared vs per-project)
- Propose mount strategy from host into containers
- Establish the security threat model for credential handling
- Define a phased implementation path from plain mounts to encrypted storage

**Non-Goals:**
- Implementing the encryption system (this is a design document)
- Defining the specific `gh auth` login flow (handled by skills)
- Specifying MCP server or agent-level credential APIs
- Addressing cloud-synced or multi-device secret sharing

## Decisions

### D1: Secrets live under ~/.cache/tillandsias/secrets/

Secrets are stored at `~/.cache/tillandsias/secrets/` on the host, organized by category (`gh/`, `git/`, `ssh/`, `per-project/`). This follows the existing tillandsias cache convention and keeps all tillandsias state under one deletable tree.

### D2: Shared by default, per-project opt-in

Most credentials (GitHub token, git identity, SSH keys) are the same person on the same machine across all projects. These are shared. Only service-specific tokens (API keys, `.env` files) are per-project. Configuration via `.tillandsias/config.toml` allows overriding this default.

### D3: Plain mounts for MVP, encrypted filesystem for Phase 2

Phase 1 uses simple volume mounts with appropriate permissions. Phase 2 introduces `gocryptfs` or LUKS-encrypted loop device with system keyring integration. This lets us ship credential support immediately while the encryption layer matures.

### D4: Agent never sees raw secrets

Secrets are mounted at paths the agent cannot read (`/bash-private` patterns, `agent_blocked` skills). Authentication flows happen through private skills that interact with the mounted credentials without exposing them to the AI conversation context.

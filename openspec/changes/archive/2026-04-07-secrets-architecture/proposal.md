## Why

Tillandsias forge containers need access to credentials (GitHub tokens, SSH keys, git identity) to perform useful work — cloning private repos, pushing commits, authenticating with APIs. Today there is no defined strategy for how secrets enter containers, persist between runs, or stay protected from the AI agent and host-level exposure.

Without a design document, implementation will make ad-hoc decisions about secret storage paths, mount strategies, and encryption that become hard to change later. The secrets architecture must be defined before forge containers ship with credential access.

## What Changes

- New `SECRETS.md` design document at the project root proposing the secrets filesystem architecture
- Defines secret categories (shared vs per-project), storage paths, mount strategy, and security model
- Proposes a phased approach: plain directory mounts now, encrypted filesystem later
- No code changes — this is a design document for review

## Capabilities

### New Capabilities
- `secrets-management`: Design specification for how tillandsias manages, stores, mounts, and protects user credentials across forge containers

### Modified Capabilities
<!-- None — this is a new design document, no existing specs affected -->

## Impact

- No code changes, no runtime impact
- Establishes `~/.cache/tillandsias/secrets/` as the canonical secrets storage path
- Constrains future implementation decisions around credential handling
- Must be reviewed and approved before any secrets-related code is written

# research: Vault Persistence Across Container Recreation

- class: research
- filed: 2026-06-23
- owner: unassigned
- status: ready

## Context
Whenever the forge or new environments are launched, the vault container might be recreated. If a previous vault container created an encrypted vault, that vault data should theoretically survive container recreation if it is stored on a persistent volume, as long as the unseal key remains in the host keyring.

## Problem
Currently, it seems we might be losing vault state (like github tokens, and later claude/codex/antigravity auth tokens) when the vault container is recreated. 

## Goals
1. Investigate how the vault data directory is currently mounted (is it an ephemeral tmpfs or a persistent podman volume?).
2. Determine how to cleanly persist the encrypted vault data across container lifecycles.
3. Ensure the unseal key from the host keyring can successfully unseal the preserved vault.
4. Implement the persistent volume mounting for the vault container.

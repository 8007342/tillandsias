## Context

Tillandsias uses a multi-layered secret management architecture to deliver GitHub credentials to containers without exposing tokens to AI agents or persistent storage. The system evolved through three phases: direct mounts (Phase 1), tmpfs token files (Phase 2), and the enclave architecture (Phase 3, current) where forge containers have zero credentials and the git service acts as a credential proxy.

The implementation is complete and traced, but the formal spec was never created. This change fills that gap.

## Goals / Non-Goals

**Goals:**
- Document the three credential delivery mechanisms: D-Bus forwarding, hosts.yml bind mounts, and tmpfs token files
- Formalize the zero-credential security boundary for forge/terminal containers
- Specify the git-askpass mechanism and `gh auth setup-git` bridge
- Specify the gh-auth-login.sh authentication strategies (host gh, container + D-Bus, container + plaintext fallback)
- Define accountability logging requirements for credential lifecycle events

**Non-Goals:**
- Changing any existing behavior (this is documentation-only)
- Specifying the native keyring integration (covered by `spec:native-secrets-store`)
- Specifying the tmpfs token rotation (covered by `spec:secret-rotation`)
- Specifying the enclave network topology (covered by `spec:enclave-network`)

## Decisions

### D1: Spec covers the credential delivery pipeline, not storage or rotation

`secret-management` is the umbrella spec for how credentials move from the host to containers. Storage is `native-secrets-store`, rotation is `secret-rotation`, and network isolation is `enclave-network`. This spec focuses on the delivery mechanisms: D-Bus forwarding, bind mounts, git-askpass, and the authentication flow.

### D2: Zero-credential boundary is a first-class requirement

Forge and terminal containers SHALL have zero credentials mounted. This is the foundational security property of the enclave architecture. The spec makes this explicit and testable.

### D3: Three authentication strategies documented in priority order

The `gh-auth-login.sh` script implements three strategies in priority order: (1) host-native gh CLI, (2) forge container with D-Bus forwarding, (3) forge container with plaintext fallback. The spec documents all three with their security properties.

### D4: Accountability logging is a requirement, not an implementation detail

Every credential lifecycle event (store, retrieve, migrate, inject, revoke) SHALL be logged to the accountability window with `@trace` references. This is part of the spec, not just good practice.

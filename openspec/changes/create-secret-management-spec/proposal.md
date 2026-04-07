## Why

An audit found 16 `@trace spec:secret-management` annotations across the codebase but no formal spec exists in `openspec/specs/`. The traces span `gh-auth-login.sh` (9 lines), `container_profile.rs`, `handlers.rs`, `launch.rs`, `runner.rs`, and `docs/cheatsheets/github-credential-tools.md`. Without a spec, the trace annotations are orphans — they reference a contract that was never written down.

The secret management subsystem is security-critical and already well-implemented. Formalizing it as a spec creates the bidirectional link between implementation and intent that OpenSpec requires: code traces point to the spec, the spec defines the requirements that govern the code.

## What Changes

- New spec `openspec/specs/secret-management/spec.md` documenting the secret management architecture
- New `openspec/specs/secret-management/TRACES.md` listing all annotated locations
- No code changes — this is a documentation-only change formalizing existing behavior

## Capabilities

### New Capabilities
- `secret-management`: Formal specification for how Tillandsias manages credential delivery to containers — D-Bus forwarding, hosts.yml bind mounts, token file infrastructure, git-askpass mechanism, and the zero-credential security boundary

### Modified Capabilities
<!-- None — this formalizes existing behavior, no other specs affected -->

## Impact

- No runtime changes — all behavior already exists and is traced
- Establishes the formal contract that 16 existing traces reference
- Related specs: `native-secrets-store` (keyring storage), `secret-rotation` (tmpfs token files), `git-mirror-service` (enclave credential proxy)

<!-- @trace spec:build-lock -->
# build-lock Specification

## Status

status: active

## Purpose
TBD - created by archiving change init-prebuilt-images. Update Purpose after archive.
## Requirements
### Requirement: Build lock coordination
Image builds MUST use a lock file to prevent duplicate concurrent builds.

#### Scenario: Acquire lock
- **WHEN** a build starts and no lock exists
- **THEN** a lock file MUST be created at `$XDG_RUNTIME_DIR/tillandsias/build-forge.lock` with the current PID

#### Scenario: Wait for existing build
- **WHEN** a build is requested and a lock exists with a live PID
- **THEN** the requester MUST poll every 2 seconds until the lock is released, then verify the image exists

#### Scenario: Stale lock
- **WHEN** a build is requested and a lock exists but the PID is dead
- **THEN** the stale lock MUST be replaced and the build MUST proceed

#### Scenario: Lock released on completion
- **WHEN** a build completes (success or failure)
- **THEN** the lock file MUST be removed


## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:build-lock" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

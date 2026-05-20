# containerfile-staleness Specification

@trace spec:containerfile-staleness

## Status

active

## Requirements

### Requirement: Runtime image source digest detects stale images

Runtime image builds that use release-shipped Containerfiles MUST compare the current runtime image source digest with the digest stored after the last successful build. The runtime MUST rebuild an image when its materialized image context changes and MUST NOT rely on repository file mtimes for installed user runtime staleness.

#### Scenario: Runtime source digest changed

- **WHEN** a versioned image exists locally but its cached source digest differs from the current release runtime asset digest
- **THEN** `tillandsias --init` MUST rebuild the affected image
- **AND** debug output SHOULD identify that runtime assets changed

#### Scenario: Developer override uses checkout sources

- **WHEN** `TILLANDSIAS_ROOT` is explicitly set to a valid checkout
- **THEN** runtime image source digests MAY be computed from that checkout's image context
- **AND** an invalid `TILLANDSIAS_ROOT` MUST fail loudly instead of falling back silently

## Sources of Truth

- `cheatsheets/runtime/image-lifecycle.md` - Image rebuild lifecycle
- `cheatsheets/runtime/image-versioning.md` - Image versioning conventions
- `cheatsheets/runtime/container-image-tagging.md` - Image tag semantics
- `cheatsheets/runtime/user-runtime-install.md` - Release runtime asset root

# containerfile-staleness Specification

@trace spec:containerfile-staleness

## Status

active

## Requirements

### Requirement: Embedded image sources detect stale workspace files

Runtime image builds that use embedded Containerfiles MUST detect when embedded image sources are older than the workspace version used for development builds.

#### Scenario: Stale embedded source is detected

- **WHEN** an embedded image source differs from the workspace source that should own the image
- **THEN** diagnostics MUST identify the affected image source
- **AND** the build path MUST avoid silently producing an image from stale embedded content

## Sources of Truth

- `cheatsheets/runtime/image-lifecycle.md` - Image rebuild lifecycle
- `cheatsheets/runtime/image-versioning.md` - Image versioning conventions
- `cheatsheets/runtime/container-image-tagging.md` - Image tag semantics


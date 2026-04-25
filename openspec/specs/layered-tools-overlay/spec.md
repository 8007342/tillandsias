# layered-tools-overlay Specification

## Purpose

Pre-built tools overlay that decouples AI coding tool lifecycle (OpenCode, Claude Code, OpenSpec) from the forge base image lifecycle. Tools are installed once into a host directory, mounted read-only into all forge containers, and updated in the background. Eliminates the 15-60 second per-launch install delay.
## Requirements
### Requirement: Capability is tombstoned

The `layered-tools-overlay` capability SHALL remain in the spec index
only as a tombstone. All operative requirements have been removed.
Any code or documentation that references this capability SHALL be
treated as legacy and migrated to `spec:default-image` (agent
hard-install) or `spec:opencode-web-session` (config overlay on
tmpfs).

#### Scenario: Tombstone visible to readers
- **WHEN** an engineer opens `openspec/specs/layered-tools-overlay/spec.md`
- **THEN** they SHALL see exactly one active requirement noting the
  tombstone
- **AND** they SHALL be pointed to the superseding specs


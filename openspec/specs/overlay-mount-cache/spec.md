<!-- @tombstone superseded:forge-cache-dual -->
# overlay-mount-cache Specification (Tombstone)

## Status

obsolete

## Tombstone

**Superseded by**: `forge-cache-dual`
**Last live**: v0.1.260513 (2026-05-14)
**Safe to delete after**: v0.1.260515

This cache-path optimization was reduced back out of the live contract. The
current launch path keeps the direct mount-resolution behavior in the codebase
for archive traceability, but no standalone cache contract remains active.

The dual-cache architecture (shared Nix store + per-project overlay) replaces
all prior cache optimization proposals. See `forge-cache-dual` for the current
live spec.

## Historical Context

The process-lifetime overlay snapshot idea was explored as a launch-path
micro-optimization, but it never became a supported spec boundary. The need
it addressed (avoiding cache conflicts and stale state) is now solved by the
dual-layer architecture with strict path segregation and ephemeral-first cleanup.

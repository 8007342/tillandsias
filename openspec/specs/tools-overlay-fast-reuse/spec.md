<!-- @tombstone superseded:forge-cache-dual -->
# tools-overlay-fast-reuse Specification (Tombstone)

## Status

obsolete

## Tombstone

**Superseded by**: `forge-cache-dual`
**Last live**: v0.1.260513 (2026-05-14)
**Safe to delete after**: v0.1.260515

This process-lifetime overlay snapshot proposal was not kept as a live
contract. The implementation path in the repository remains traceable for
historical context, but there is no supported cache-reuse requirement left to
verify.

The dual-cache architecture now provides deterministic, conflict-free caching
through strict path segregation (shared read-only Nix store + per-project
read-write overlays). See `forge-cache-dual` for the replacement spec.

## Historical Context

The optimization was explored as a follow-on to the overlay lifecycle work, but
the cache contract did not survive the frontier cleanup. The newer dual-layer
model with ephemeral-first cleanup provides better guarantees without the
complexity of overlay snapshots.

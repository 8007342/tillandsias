<!-- @tombstone superseded:project-summarizers+project-bootstrap-readme+filesystem-scanner+init-command+forge-staleness -->
# artifact-detection Specification (Tombstone)

## Status

obsolete

## Deprecation Notice

This umbrella spec has been retired. Its live obligations are now covered by:

- `project-summarizers` for manifest-driven project type detection
- `project-bootstrap-readme` for project metadata summarization and README generation
- `filesystem-scanner` for watch-based project discovery
- `init-command` for image build orchestration and build-state tracking
- `forge-staleness` for source-hash freshness and canonical image reuse

The old `artifact-detection` contract mixed heuristics, runtime metadata, and
image-state checks into one blob. The project now treats those concerns as
separate, narrower boundaries.

There is no backwards-compatibility commitment.

## Historical Context

`artifact-detection` originally grouped together:

- standard file detection for project types
- runtime config discovery
- built-image detection
- Nix and containerfile build heuristics

Those concerns are now handled by the narrower specs listed above.

## Replacement References

- `openspec/specs/project-summarizers/spec.md`
- `openspec/specs/project-bootstrap-readme/spec.md`
- `openspec/specs/filesystem-scanner/spec.md`
- `openspec/specs/init-command/spec.md`
- `openspec/specs/forge-staleness/spec.md`

<!-- @tombstone superseded:cheatsheet-tooling+cheatsheet-source-layer+cheatsheets-license-tiered+spec-traceability+default-image -->
# agent-cheatsheets Specification (Tombstone)

## Status

obsolete

## Deprecation Notice

This umbrella spec has been retired. Its remaining live obligations now live in:

- `cheatsheet-tooling` for the cheatsheet tree layout, template, and generated index
- `cheatsheet-source-layer` for source binding and local verification
- `cheatsheets-license-tiered` for tier/frontmatter and bake rules
- `spec-traceability` for `@trace`, `@cheatsheet`, and litmus-chain references
- `default-image` for the forge image's cheatsheet bake and runtime view

There is no backwards-compatibility commitment. Existing `@trace spec:agent-cheatsheets`
references are historical and may remain as drift signals until touched.

## Historical Context

This spec originally bundled cheatsheet structure, provenance, runtime limitation
reporting, image-bake behavior, and traceability guidance into one umbrella.
Those obligations have since been distilled into narrower homes so the build
surface can fail on smaller, actionable boundaries.

## Replacement References

- `openspec/specs/cheatsheet-tooling/spec.md`
- `openspec/specs/cheatsheet-source-layer/spec.md`
- `openspec/specs/cheatsheets-license-tiered/spec.md`
- `openspec/specs/spec-traceability/spec.md`
- `openspec/specs/default-image/spec.md`

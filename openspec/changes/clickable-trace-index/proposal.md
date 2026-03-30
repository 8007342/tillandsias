## Why

`@trace spec:<name>` comments in source files create a navigational chain from code back to the specification that justified a decision. But the chain breaks on GitHub: code comments are not hyperlinks, so a reader sees `@trace spec:podman-orchestration` and has no direct path to the spec file.

A generated `TRACES.md` index closes the gap. It maps every trace reference in the codebase to a clickable link, so the chain `code → TRACES.md → spec.md` works from any GitHub file view. Companion per-spec `TRACES.md` files provide the reverse direction: from spec to every implementing file.

This is the second half of the traceability work started in `add-spec-traceability-refs`. That change added the `@trace` comments; this change makes them navigable.

## What Changes

- Add `scripts/generate-traces.sh` — scans all `.rs`, `.sh`, `.toml`, `.nix` files for `@trace spec:<name>` patterns, then generates:
  - `TRACES.md` at the repo root: one table row per unique spec name, with links to the spec file and all source locations (with `#L<n>` anchors)
  - `openspec/specs/<name>/TRACES.md` per referenced spec: back-links from spec to implementing files
- Add `TRACES.md` to `build.sh` — auto-regenerated on every non-test build alongside the version bump
- Generate the initial `TRACES.md` from the 38 existing trace annotations

## Capabilities

### New Capabilities

- `clickable-trace-index`: Generated trace index mapping `@trace` comments to clickable spec and source links, navigable on GitHub without plugins or GitHub Actions

### Modified Capabilities

- `dev-build`: `build.sh` runs `generate-traces.sh` after every build so the index stays current

## Impact

- New `scripts/generate-traces.sh` — shell script, no external dependencies
- New `TRACES.md` at repo root — generated file, safe to commit
- New `openspec/specs/<name>/TRACES.md` per spec — generated companion files
- Modified `build.sh` — one line calling `generate-traces.sh` after version bump

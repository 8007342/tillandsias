## Why

OpenSpec guarantees implementation converges to spec. But what keeps the spec itself correct? Today, agents infer best practices from training data — non-deterministic and uncitable. A local, cached source of truth for the tech stack means agents cite verified facts instead of guessing. This completes the convergence chain: implementation → spec → ground truth.

Critical now because we're pushing container boundaries (FUSE FD leaks, OCI runtime internals, cross-platform namespaces) where inference-based knowledge is unreliable.

## What Changes

- Add `knowledge/` directory as a project-agnostic source of truth
- YAML-frontmattered Markdown cheatsheets, one per focused topic (~2-4K tokens each)
- XML `index.xml` for structured category/tag querying
- `manifest.toml` for version tracking and freshness auditing
- Subdirectories by domain: `infra/`, `lang/`, `frameworks/`, `packaging/`, `formats/`, `ci/`
- Bootstrap Tier 1 cheatsheets (6) covering core infrastructure
- Fetch script for pulling upstream docs as reference material

## Capabilities

### New Capabilities

- `knowledge-source-of-truth`: Local cached source of truth for tech stack — project-agnostic cheatsheets with structured indexing, versioned against upstream official docs

### Modified Capabilities

(none — knowledge is parallel to OpenSpec, not embedded in it)

## Impact

- New `knowledge/` directory tree (committed to git, not gitignored)
- New `scripts/fetch-debug-source.sh` for on-demand external source fetching
- New `vendor/debug/` gitignore entry for debug sources
- Future: OpenSpec skill files will be patched to include "consult knowledge/" instructions

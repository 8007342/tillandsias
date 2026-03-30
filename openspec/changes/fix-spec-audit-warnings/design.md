## Context

A knowledge audit compared the spec corpus against verified cheatsheets and found 6 WARNING-level inaccuracies. Each is a wording issue in an existing spec — no code changes are needed because the implementation already behaves correctly. The specs must be updated to match reality.

## Goals / Non-Goals

**Goals:**
- Correct all 6 factual inaccuracies in spec files
- Ensure every spec assertion is backed by the verified knowledge base
- Maintain monotonic convergence between specs and implementation

**Non-Goals:**
- Changing any code, configuration, or runtime behavior
- Rewriting specs beyond the minimum needed to fix each finding
- Adding new features or capabilities

## Decisions

1. **Each fix is a surgical wording edit** — the smallest change that corrects the inaccuracy. No restructuring.
2. **Knowledge base citations inform the corrections** but are not inlined into the spec text. The spec states facts; the knowledge base is the verification layer.
3. **The FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 caveat is added as a scenario** rather than removing the requirement, because the env var is in use and functional — it just lacks upstream documentation in the knowledge base.

## Risks / Trade-offs

- **Low risk**: All changes are spec-only wording corrections with no implementation impact.
- **Trade-off on finding #6 (ci-release)**: Adding a validation caveat to an env var requirement is less clean than removing it, but removing it would create a false divergence since the env var is actually set in the workflow files.

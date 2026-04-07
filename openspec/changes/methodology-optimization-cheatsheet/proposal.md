## Why

A thorough audit of the OpenSpec methodology across the Tillandsias codebase revealed both strengths (273 traces, 142 changes archived in ~14 days, excellent enclave spec alignment) and systematic weaknesses (35% of main specs with zero traces, 8 ghost trace names, 4 unsynced archives, TRACES.md line-number drift). There is no single reference document that captures how to use OpenSpec effectively, what healthy convergence looks like, or how to detect and prevent divergence.

Without a cheatsheet, each new agent or contributor rediscovers these patterns from scratch. The audit findings are ephemeral conversation output unless captured in the project's operational knowledge base.

## What Changes

- **New cheatsheet**: `docs/cheatsheets/openspec-methodology.md` — a scannable reference covering the full OpenSpec workflow, trace annotation guidelines, convergence metrics from the audit, lightweight vs full change criteria, common divergence patterns, and optimization rules of thumb.
- Cheatsheet includes `@trace spec:spec-traceability` linking it to the governing spec.

## What Stays

- No changes to the OpenSpec workflow itself, CLAUDE.md, or any spec files.
- No code changes — this is documentation only.
- The audit findings are presented as a snapshot, not as automated enforcement (automation is a separate future change).

## Capabilities

### Referenced Capabilities
- `spec-traceability`: Cheatsheet documents how to use trace annotations correctly

## Impact

- **New file**: `docs/cheatsheets/openspec-methodology.md`
- **Risk**: None — documentation only
- **User-visible change**: None (internal operational knowledge)

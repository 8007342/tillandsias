## Why

The `agent-source-of-truth` change shipped 60 cheatsheets and a methodology that mandated `## Sources of Truth` in specs. **It did not mandate provenance in the cheatsheets themselves.** I (the agent) generated all 60 cheatsheets from training-data memory — the user caught this and rejected the result, twice. Cheatsheets without provenance are worse than no cheatsheets: they look authoritative but propagate hallucinated content into every spec that cites them, completely breaking the convergence-toward-truth model the source-of-truth foundation was supposed to provide.

Two further methodology gaps surfaced in the same conversation:

1. **No code-level tombstone discipline.** Removing dead code without a trace destroys the audit trail of "why did this used to do X?". Specs already capture removals via `## REMOVED Requirements`, but there was no equivalent for code.
2. **No staleness/refresh cadence for cheatsheets.** Even with provenance, cheatsheets rot when their underlying tools ship. We need an automatable refresh discipline.

This change codifies all three (provenance, tombstone, staleness) as the canonical methodology for `agent-cheatsheets` going forward, AND tracks the work to retroactively bring the existing 60 cheatsheets up to standard.

## What Changes

- **NEW (methodology)** Every cheatsheet under `cheatsheets/` SHALL include a `## Provenance` section with:
  - At least one URL pointing to a high-authority source (vendor docs, standards body, RFC, IETF, W3C/WHATWG, Mozilla MDN, recognised community project's own docs).
  - A `**Last updated:** YYYY-MM-DD` line — the date the agent verified the cited URL still matches the cheatsheet content.
- **NEW (methodology)** Stack Overflow, blogs, and AI-generated content are NEVER acceptable as sole provenance. They MAY appear as secondary references (named as such) but a cheatsheet listing only those is REJECTED.
- **NEW (methodology)** Cheatsheets without provenance are flagged DRAFT with the existing banner, citing this change. They MAY ship in the forge image but MUST NOT be cited under a spec's `## Sources of Truth` until they reach non-DRAFT state.
- **NEW (methodology)** Cheatsheet citation traceability — code (`// @cheatsheet path`), shell (`# @cheatsheet path`), log events (`cheatsheet = "path"` field), and OpenSpec `## Sources of Truth` all cite cheatsheets the same way `@trace spec:` cites specs. Makes the cheatsheet→code→spec graph queryable.
- **NEW (tombstone methodology)** Dead code is commented-out (not silently deleted) with `// @tombstone superseded:<new-spec>` or `// @tombstone obsolete:<old-spec>` annotation. Kept three releases for cadence-based projects (Tillandsias) or three committed builds for local-only projects. Then deleted in a normal commit. Spec-level tombstones already exist via OpenSpec's `## REMOVED Requirements` `**Reason**:` / `**Migration**:` fields — code tombstones complement them.
- **NEW (refresh discipline)** Each cheatsheet's `**Last updated:** YYYY-MM-DD` line drives a soft staleness check: cheatsheets older than N days (project-defined, default 90) are flagged for re-verification. The check is implemented as a host-side script (`scripts/check-cheatsheet-staleness.sh`, future task) and surfaced in the tray's RUNTIME_LIMITATIONS feedback channel.
- **NEW (retroactive sweep work)** All 60 existing cheatsheets are tracked in `tasks.md` for retrofitting. Sweep happens in waves with a small per-wave token budget. Each cheatsheet's retrofit agent SHALL `WebFetch` (or equivalent verification) against the cited URLs and refuse to add a `## Provenance` section it can't actually back.
- **MODIFIED** `agent-cheatsheets` capability (existing): `## Provenance` section is now mandatory; existing cheatsheets remain valid only with the DRAFT banner.
- **MODIFIED** `spec-traceability`: `## Sources of Truth` references SHOULD prefer non-DRAFT cheatsheets. Citing a DRAFT cheatsheet emits a `openspec validate` warning (existing warn-not-error path).

## Capabilities

### New Capabilities
None. Two existing capabilities get hardened.

### Modified Capabilities
- `agent-cheatsheets`: provenance section mandatory; DRAFT banner system; refresh-cadence framework; cheatsheet citation traceability through code/logs.
- `spec-traceability`: warn when specs cite DRAFT cheatsheets; document the `@cheatsheet path` annotation as a peer of `@trace spec:`.

## Impact

- `cheatsheets/TEMPLATE.md` — gain a `## Provenance` section with example fields. Future cheatsheets fail review without it.
- `cheatsheets/INDEX.md` — gain a per-line marker (e.g., `[DRAFT]` prefix) for non-provenance cheatsheets so the index is scannable.
- All 60 existing cheatsheets — retrofit work tracked in `tasks.md` (60 task lines). Estimated 5–10 retrofit waves.
- `scripts/check-cheatsheet-staleness.sh` (new, future) — cron-eligible staleness check.
- `cheatsheets/runtime/cheatsheet-methodology.md` (new) — meta-cheatsheet documenting the methodology itself, with provenance citing the OpenSpec change ID + this project's CLAUDE.md.
- Project + workspace `CLAUDE.md` — already updated in commit `1d4274b`. Spec deltas will reference those edits.
- Tray + forge image — no change. The sweep is content-only.
- No new code paths in `src-tauri/`. The methodology is enforced at review time + by `openspec validate` warnings.

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` (DRAFT) — the forge runtime contract this methodology operates inside.
- `cheatsheets/agents/openspec.md` (DRAFT) — the workflow this change goes through.

(Both are DRAFT — fixing this is what the change DOES. The dependency loop is acknowledged: this change cannot rest on non-DRAFT provenance because the provenance methodology is what it codifies.)

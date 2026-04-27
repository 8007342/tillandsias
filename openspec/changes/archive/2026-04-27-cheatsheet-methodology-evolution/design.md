# Design: Cheatsheet Methodology Evolution

## Overview

This change codifies three foundational methodology improvements for the `agent-cheatsheets` capability:

1. **Provenance requirement** — every cheatsheet cites at least one high-authority external source URL and records when it was last verified
2. **Tombstone discipline** — dead code is annotated (not silently deleted) with a 3-release retention window
3. **Staleness detection** — a soft-warning refresh cadence identifies cheatsheets older than 90 days, prompting re-verification

All three follow the "monotonic convergence" principle: the system moves toward verified, authoritative content over time without silent gaps.

## Key Decisions

### Decision 1: Provenance over convenience

Cheatsheets without provenance are worse than no cheatsheets — they look authoritative but propagate hallucinated content. Rather than ship unverified cheatsheets and hope reviewers catch problems, we mandate verification upfront:

- Every cheatsheet lists at least one canonical source (vendor docs, RFC, standards body, recognized community project)
- Stack Overflow, blogs, and AI-generated content are NEVER primary sources — they may appear as secondary references only
- The `**Last updated:** YYYY-MM-DD` line is a commit-time contract: the author verified the cited URLs match the cheatsheet content
- DRAFT banner flags retrofitted cheatsheets still pending provenance, making the gap machine-readable

**Trade-off**: Slower initial development (each cheatsheet requires research), faster long-term quality (specs can now safely cite cheatsheets, specs themselves become more trustworthy).

### Decision 2: Soft staleness, not hard failure

Tools ship breaking changes. A cheatsheet's `Last updated:` date rots when its pinned tool version ships. We detect this softly:

- `scripts/check-cheatsheet-staleness.sh` flags cheatsheets older than 90 days (configurable)
- The check is non-blocking — staleness does NOT fail builds
- It surfaces as informational logs and RUNTIME_LIMITATIONS signals
- Refresh is manual (or agent-driven in future waves) — never automatic

**Why soft?** Hard failures for staleness would lock the build whenever any tool ships, which is too fragile. Soft warnings let the team batch refreshes and prioritize by impact.

### Decision 3: Tombstone + code citation as peers of @trace spec:

Dead code vanishes silently; dead specs live in OpenSpec's `## REMOVED Requirements` section. We bridge this gap:

- `@tombstone superseded:<new>` or `@tombstone obsolete:<old>` annotations mark removed code
- Comments stay (not deleted) for 3 releases (Tillandsias' cadence is Major.Minor.ChangeCount.Build)
- This complements OpenSpec's spec-level tombstones to form a complete audit trail
- Cheatsheets are cited with `@cheatsheet <category>/<filename>.md` — a peer annotation to `@trace spec:`

**Result**: `git log -G '@tombstone'`, `git grep '@cheatsheet'`, and OpenSpec's `## Sources of Truth` become a navigable graph of behavioural lineage.

## Implementation

### Cheatsheets: retrofitted to Provenance-first (Wave 1 complete)

All 93 existing cheatsheets now carry:
- `## Provenance` section with at least one URL and `**Last updated:** YYYY-MM-DD`
- No DRAFT banner (they passed retrofit)
- TEMPLATE.md enforces the section on all new cheatsheets

**Retrofit validation**: Each cheatsheet's provenance was spot-checked via `WebFetch` or manual verification against cited URLs.

### CLAUDE.md: methodology codified

**Added sections**:
- `@tombstone` — 3-release retention discipline + required fields
- `Cheatsheet citation traceability` — `@cheatsheet path` as a peer of `@trace spec:`
- `Cheatsheet refresh cadence and staleness detection` — 90-day soft check, manual refresh workflow

**Existing sections updated**:
- `Provenance is mandatory` — now references the full spec
- Template enforcement and length budgets tied to `cheatsheets/TEMPLATE.md`

### Tooling: staleness check script

`scripts/check-cheatsheet-staleness.sh`:
- Walks all cheatsheets in `$TILLANDSIAS_CHEATSHEETS`
- Extracts `**Last updated:**` date from each
- Flags any older than 90 days (configurable with `--days N`)
- Optionally checks URL reachability with `--check-urls` (slow, network-dependent)
- Exit code 0 if all current; 1 if staleness found (no build failure)

**Future enhancements** (out of scope for this change):
- CI workflow (`workflow_dispatch`) that runs the check on schedule
- Agent task that re-verifies stale cheatsheets automatically
- Telemetry field `staleness_days` on RUNTIME_LIMITATIONS events

### Specs: two delta capabilities

1. **agent-cheatsheets**: Provenance requirement, DRAFT banner system, citation traceability, refresh cadence
2. **spec-traceability**: SHOULD prefer non-DRAFT cheatsheets; warn if citing DRAFT (non-blocking)

Both specs sit in the change directory and are synced to main specs at archive time.

## Acceptance Criteria

✅ **All implemented:**

1. **Provenance coverage** — 93/93 cheatsheets have `## Provenance` with ≥1 URL + `Last updated:` date
2. **INDEX.md** — lists all cheatsheets; DRAFT status markers (none remain; all retrofitted)
3. **CLAUDE.md** — provenance, @tombstone, @cheatsheet, staleness/refresh cadence sections
4. **TEMPLATE.md** — updated with mandatory `## Provenance` section
5. **Tooling** — `scripts/check-cheatsheet-staleness.sh` complete and documented
6. **Spec convergence** — no specs currently cite DRAFT cheatsheets; `openspec validate` can warn if they do

## Convergence Story

This change closes a methodological loop that began with `agent-source-of-truth`:

| Stage | Artifact | Status |
|-------|----------|--------|
| Proposal | `openspec/changes/.../proposal.md` | ✅ Complete |
| Delta Specs | `openspec/changes/.../specs/**/*.md` | ✅ Complete |
| Tasks | `openspec/changes/.../tasks.md` | ✅ All marked done |
| Implementation | CLAUDE.md, cheatsheets/, scripts/ | ✅ Complete |
| Validation | `openspec validate cheatsheet-methodology-evolution --strict` | ✅ Passes |
| Archive | Ready for `/opsx:archive` | ✅ Ready |

The three gaps (provenance, tombstone, staleness) are now codified in project methodology, enforced at review time, and automated where appropriate.

## Sources of Truth

- `cheatsheets/agents/openspec.md` (non-DRAFT) — workflow this change is part of
- `cheatsheets/runtime/forge-container.md` (non-DRAFT) — runtime contract for cheatsheets
- OpenSpec change: `cheatsheet-methodology-evolution` (this change)

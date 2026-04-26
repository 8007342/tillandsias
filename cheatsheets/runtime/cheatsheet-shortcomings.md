---
tags: [meta, cheatsheet-system, technical-debt, mcp]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md
  - https://github.com/8007342/tillandsias/blob/main/cheatsheets/TEMPLATE.md
authority: high
status: current
---

# Cheatsheet system — shortcomings noticed during the v2 sweep

@trace spec:agent-cheatsheets, spec:cheatsheet-methodology-evolution
@cheatsheet runtime/cheatsheet-architecture-v2.md, runtime/cheatsheet-frontmatter-spec.md

## Provenance

This file is project-internal observation documenting gaps found during the first v2 cheatsheet sweep. Authority is the Tillandsias project and the observable limitations of the cheatsheet tooling at the time of writing.
- Cheatsheet index (the gap in automated sync this file describes): <https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md>
- Cheatsheet template (authoring contract, granularity guidance this file critiques): <https://github.com/8007342/tillandsias/blob/main/cheatsheets/TEMPLATE.md>
- **Last updated:** 2026-04-25

## Use when

You're prioritising work on the cheatsheet system itself. Each item below was noticed first-hand while writing the v2 sweep — they're not theoretical concerns, they're things that bit me in this exact session.

## Shortcomings, ranked by impact

### 1. Cross-references are fragile and untested

I wrote `@cheatsheet patterns/gof-observer.md` from inside `architecture/reactive-streams-spec.md` — and pointed it at a file I just created. If the path is wrong, nothing fails. Same for `## See also` links — they're plain text references, not tested.

**Fix:** A `scripts/check-cheatsheet-refs.sh` that walks every `@cheatsheet`, `## See also` link, and `cheatsheet=` log field, asserting each resolves. Should fail CI (or at least emit warnings into a tracked file). Effort: 1 day. Should ship as part of `cheatsheet-tooling`.

### 2. INDEX.md drifts the moment you add a new file

I created 10 new cheatsheets in this session. `INDEX.md` doesn't know about any of them yet — it's a manual sync. The legacy 60 cheatsheets all carry `[DRAFT]` markers in INDEX.md added by `agent-source-of-truth`, but there's no automation keeping new entries in sync.

**Fix:** `scripts/regenerate-cheatsheet-index.sh` that walks the tree, reads each frontmatter, and rebuilds INDEX.md from scratch. Run on every commit touching `cheatsheets/`. Effort: half a day.

### 3. No way to grep by tag — frontmatter is human-readable but not machine-indexed

The `tags: [java, rxjava, async, event-driven]` line is YAML, but `rg "rxjava" cheatsheets/` still returns body matches first. The MCP server design promises tag-aware ranking — but until it exists, agents (and I) can't query by tag at all.

**Fix:** Either (a) the MCP server (Implementation H, see proposed changes below), or (b) an interim `scripts/cheatsheets-by-tag.sh <tag>` that just `awk`s the frontmatter and prints matching paths. (b) is half a day; (a) is part of the larger MCP host change.

### 4. Provenance verification is on the honour system

I cited `https://www.reactive-streams.org/` claiming it's the official spec — and it is, but no automation checks: (i) the URL still resolves, (ii) the URL still says what I claimed it says. Three months from now, dead links and content drift will silently rot the cheatsheets.

**Fix:** Two-stage tooling:
- `scripts/check-cheatsheet-provenance-reachability.sh` — `curl -fsSI` every `sources:` URL, fail on 4xx/5xx/timeout. Easy.
- A semantic drift check is harder (requires fetching content + comparing against a stored hash of "what I claimed it said"). Defer that until URL-reachability tooling is in place.

### 5. `last_verified` doesn't drive any visible signal yet

I wrote `**Last updated:** 2026-04-25` in 10 files. Tomorrow they're "current". 90 days later they'd be "stale" by spec — but nothing surfaces this. The MCP design promises a `cheatsheet.stale_check()` tool; until it exists, staleness is invisible.

**Fix:** Same `scripts/check-cheatsheet-staleness.sh` already enumerated in `cheatsheet-methodology-evolution`'s tasks.md §11.1. Just hasn't been written yet. Half a day.

### 6. Granularity guideline is fuzzy ("split when approaching 200 lines")

I split RxJava into "event-driven" without writing the matching "error-handling" / "backpressure" siblings. Future me (or another agent) might re-merge them out of confusion about what the splits should be. The guideline needs concrete naming examples per category.

**Fix:** Add an "Examples of good splits" section to `cheatsheet-architecture-v2.md`. Maybe a few hours.

### 7. The DRAFT/current/stale/deprecated status enum has no enforcement

I declared `status: current` on 10 new cheatsheets. Nothing checks I actually verified them. The legacy 60 carry `status: ?` (no frontmatter at all — they predate the spec). The frontmatter-spec defines the values; nothing reads them.

**Fix:** Same toolchain as items 1-5 will read and enforce these. The architecture is sound; tooling is missing.

### 8. Examples in cheatsheets are not compiled or run

The Java code in `rxjava-event-driven.md` is plausible but hasn't actually been compiled. Same for the Nix flake examples in `nix-flake-basics.md`. If RxJava 4.x changes its API, my snippet rots silently.

**Fix:** Long-term: extract code blocks tagged with a runnable language into a per-cheatsheet test harness. Run in CI. Major effort (2+ weeks for the framework, ongoing per-snippet). Not lamport-time-0; defer.

### 9. The "see also" graph is not navigable as a graph

I link from `gof-observer.md` to `architecture/event-driven-basics.md`, which links back. But neither cheatsheet shows me "what links HERE" (incoming edges). For an agent doing breadth-first discovery, knowing both directions matters.

**Fix:** Same regenerate-INDEX tooling can compute incoming-link sets and append a "Referenced by" section to each file. Half-day on top of the index regen.

### 10. Host-side MCP doesn't exist yet — I (host Claude) can't dogfood

This sweep produced 10 cheatsheets. I want to query them the way a forge agent would. There's no MCP server yet — I use `Read` and `Bash rg` instead. That works but it isn't fast, and crucially it doesn't surface tag-aware ranking. So I can't actually validate that the architecture solves the agent-discoverability problem until the MCP exists.

**Fix:** Build a minimal `mcp-cheatsheet-server` (Rust, single-file stdio JSON-RPC) that implements `cheatsheet.search`, `cheatsheet.get`, `cheatsheet.related`, `cheatsheet.list`, `cheatsheet.stale_check`. Same binary works on host (for me) and inside the forge (for agents). Effort: 2-3 days. Highest leverage of the items in this list.

## Proposed OpenSpec changes (in priority order)

| # | Change | Addresses | Size |
|---|---|---|---|
| 1 | `cheatsheet-tooling-and-mcp` | Items 1–5, 7, 9, 10 — combined toolchain + MCP server | L |
| 2 | `cheatsheet-granularity-examples` | Item 6 | XS |
| 3 | `cheatsheet-runnable-snippets` | Item 8 | L (defer) |

Item 1 is the high-leverage move: a single change that builds the MCP server + the supporting scripts (index regen, ref check, provenance reachability check, staleness check). Until it ships, every shortcoming above is invisible to anyone except the human who ran the sweep.

## Lamport time 0 — what we have

Despite all the above, the v2 sweep delivered something that didn't exist 30 minutes ago:

- A documented **architecture** (`cheatsheet-architecture-v2.md`).
- A documented **frontmatter contract** (`cheatsheet-frontmatter-spec.md`).
- 10 **exemplar fine-grained cheatsheets** with proper provenance, demonstrating the new style across 7 categories: algorithms, patterns, architecture, languages/java, security, data, build.
- This **honest gap inventory** so future work is targeted, not speculative.

The 60 legacy DRAFT cheatsheets remain DRAFT — their retrofit is its own scoped sweep (`cheatsheet-methodology-evolution`'s tasks.md §3-9) and ships independently. The new v2 ones ship `status: current` because they were written under the new methodology.

## See also

- `runtime/cheatsheet-architecture-v2.md` — the structure
- `runtime/cheatsheet-frontmatter-spec.md` — the schema
- `agents/openspec.md` (DRAFT) — workflow

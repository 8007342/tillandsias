## Context

Tillandsias uses OpenSpec for monotonic convergence (code → spec). But the spec itself can drift from ground truth when agents write requirements based on inference rather than verified facts. The FUSE FD leak fix is a prime example: an agent needed to know how crun handles `/proc/self/fd` — training data was insufficient, web research was required.

A `./knowledge/` directory provides cached, version-pinned, human-verified cheatsheets from official upstream sources. Agents consult these when writing specs, designing solutions, or verifying implementations.

## Goals / Non-Goals

**Goals:**
- Establish `knowledge/` as the project-agnostic source of truth for all tech stack decisions
- Format optimized for LLM agent consumption (one file per topic, ~2-4K tokens, structured frontmatter)
- XML index for category/tag querying across the collection
- Freshness tracking via manifest.toml
- Bootstrap with 6 Tier 1 cheatsheets covering core infrastructure

**Non-Goals:**
- Replacing OpenSpec (knowledge is parallel, not integrated)
- Auto-generating cheatsheets (each is human/agent-curated from official sources)
- Making knowledge project-aware (it is deliberately project-agnostic)
- Upstream OpenSpec integration (future work, after we validate the pattern)

## Decisions

**YAML frontmatter + Markdown body** over full XML: LLMs parse Markdown natively. XML adds verbosity without proportional benefit. YAML frontmatter provides the structured metadata (id, category, tags, upstream URL, version_pinned, last_verified, authority) needed for indexing. The XML index.xml covers collection-level querying.

**One file per focused topic** over monolithic per-technology: `podman-rootless.md` not `podman.md`. Each file fits in a single context load. Agent reads one file, gets everything on that topic.

**Subdirectories by domain** over flat: `infra/`, `lang/`, `frameworks/`, `packaging/`, `formats/`, `ci/` — mirrors how agents think about technology categories.

**Committed to git** over gitignored: Cheatsheets are curated knowledge, not generated cache. They should be reviewed in PRs and shared across the team.

**Parallel to OpenSpec** over embedded: Knowledge has a different lifecycle (verify against upstream) than specs (propose → implement → archive). Coupling them would be forced. Integration happens through agent practice — skills instruct agents to consult knowledge, not through tooling enforcement.

**`vendor/debug/` gitignored** for external debug sources: On-demand fetch via script, never committed. Separate concern from knowledge cheatsheets.

## Risks / Trade-offs

- [Risk] Cheatsheets go stale → `manifest.toml` tracks `last_verified` dates; `scripts/verify-freshness.sh` flags entries older than 6 months
- [Risk] Agents ignore knowledge/ → mitigated by patching OpenSpec skill instructions (future change)
- [Risk] Knowledge contradicts spec → this is the POINT — it surfaces spec drift that needs correction
- [Trade-off] Manual curation is slow but ensures accuracy; auto-generation would be fast but unreliable

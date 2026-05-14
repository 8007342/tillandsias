---
tags: [meta, cheatsheet-system, architecture, mcp, methodology]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md
  - https://github.com/8007342/tillandsias/blob/main/cheatsheets/TEMPLATE.md
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Cheatsheet architecture (v2 — fine-grained, MCP-queryable)

@trace spec:cheatsheet-tooling, spec:cheatsheet-source-layer, spec:cheatsheets-license-tiered, spec:spec-traceability

## Provenance

This file documents Tillandsias-internal cheatsheet architecture. The authority is the project itself.
- Cheatsheet index (structure source of truth): <https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md>
- Cheatsheet template (authoring contract): <https://github.com/8007342/tillandsias/blob/main/cheatsheets/TEMPLATE.md>
- **Last updated:** 2026-04-25

## Use when

You're writing, splitting, or querying cheatsheets — or designing the MCP server that will surface them to agents.

## The shape

Cheatsheets are **fine-grained per-use-case snippets**, not encyclopedic per-tool monoliths. The unit of organisation is "what an agent might query in one breath", not "what a tool documents in its README".

```
cheatsheets/
├── INDEX.md                    grep-friendly catalogue of every snippet
├── TEMPLATE.md                 the canonical authoring shape
├── runtime/                    Tillandsias-internal runtime contracts
├── agents/                     Claude Code, OpenCode, OpenSpec how-tos
├── languages/                  per-language syntax + idioms (use-case slices)
├── utils/                      single-CLI references (git, jq, ssh, etc.)
├── build/                      build tools (cargo, gradle, nix, etc.)
├── web/                        protocols + APIs (HTTP, gRPC, WebSocket, OpenAPI)
├── test/                       test frameworks (pytest, JUnit, Playwright)
├── patterns/                   software design patterns (GoF + enterprise)
├── algorithms/                 algorithmic primitives (search/sort/traversal)
├── architecture/               cross-cutting design (event-driven, reactive)
├── security/                   OWASP, threat models, secret management
├── privacy/                    GDPR/CCPA principles, data minimisation
└── data/                       database engines, schema design, indexing
```

## Granularity rule

**One file per agent-question.** When an agent asks "how do I write an async Java function using RxJava event-driven", the answer should fit in **one** cheatsheet — not require reading three.

Concrete sizing:
- Target: 60–150 lines per file.
- Hard cap: 200 lines (matches existing TEMPLATE.md guidance).
- When a file approaches the cap, SPLIT by use-case slice — not by topic. E.g., RxJava splits into `rxjava-event-driven.md`, `rxjava-error-handling.md`, `rxjava-backpressure.md` — NOT into one giant `rxjava.md` covering all three.

## Frontmatter (for MCP queryability)

Every cheatsheet SHALL carry YAML frontmatter immediately above the title:

```yaml
---
tags: [java, rxjava, async, event-driven]
languages: [java]
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://reactivex.io/
  - https://github.com/ReactiveX/RxJava
authority: high      # high | medium | community
status: current      # current | draft | stale | deprecated
---
```

Fields:
- `tags` — keywords the MCP search ranks against (lowercase, kebab-case).
- `languages` — when applicable; lets the MCP filter by language context.
- `since` — date the cheatsheet was first authored.
- `last_verified` — date last cross-checked against cited sources. Drives the staleness check.
- `sources` — provenance URLs (the same ones cited in `## Provenance`). Repeated here for machine parsing.
- `authority` — `high` (vendor / standards body / RFC), `medium` (recognised community project's own docs), `community` (broader community sources, must be paired with at least one `high`).
- `status` — `current` (good to use), `draft` (provenance pending — block citations from specs), `stale` (last_verified > 90 days, needs refresh), `deprecated` (kept for traceability per @tombstone, do not cite).

## MCP query interface (planned)

Future host-side and forge-side MCP server (same protocol, same on-disk tree):

| Tool | Input | Output |
|---|---|---|
| `cheatsheet.search(query, max_results=5)` | `"async java rxjava"` | top-N matches: `[{path, title, tags, score, snippet}]` |
| `cheatsheet.get(path)` | `"languages/java/rxjava-event-driven.md"` | full body + frontmatter |
| `cheatsheet.related(path, max=5)` | a path | `[paths]` from the file's `## See also` |
| `cheatsheet.list(category=None, status=None, tag=None)` | filter args | matching paths |
| `cheatsheet.stale_check()` | — | `[paths]` whose `last_verified` is > 90 days old |

The search ranks by: tag overlap (heaviest), title match, body keyword count, recency, authority. Snippet returned is the first matching `## <heading>` block, not the whole file.

## Citation traceability

Code, log events, specs, and OTHER CHEATSHEETS that derive from a snippet SHALL cite it via `@cheatsheet <category>/<path>.md`. This makes the cheatsheet → consumer graph queryable by `git grep '@cheatsheet'`.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md`
- **License:** see-license-allowlist
- **License URL:** https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://github.com/8007342/tillandsias/blob/main/cheatsheets/INDEX.md" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/cheatsheet-architecture-v2.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — the frontmatter schema in detail
- `cheatsheets/runtime/cheatsheet-shortcomings.md` — what's still wrong, ordered by impact
- `cheatsheets/agents/openspec.md` (DRAFT) — the workflow this architecture is part of

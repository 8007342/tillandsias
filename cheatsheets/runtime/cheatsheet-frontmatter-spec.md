---
tags: [meta, cheatsheet-system, frontmatter, mcp]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://yaml.org/spec/1.2.2/
  - https://jekyllrb.com/docs/front-matter/
authority: high
status: current
---

# Cheatsheet frontmatter spec

@trace spec:agent-cheatsheets, spec:cheatsheet-methodology-evolution
@cheatsheet runtime/cheatsheet-architecture-v2.md

## Provenance

- YAML 1.2.2 spec: <https://yaml.org/spec/1.2.2/> — the syntax
- Jekyll's front matter convention (the prevailing markdown-with-YAML pattern): <https://jekyllrb.com/docs/front-matter/>
- **Last updated:** 2026-04-25

## Use when

Authoring or refreshing a cheatsheet — this defines the YAML block at the top of every file.

## Schema

```yaml
---
tags: [list, of, kebab-case, keywords]
languages: [list-of-language-slugs]
since: YYYY-MM-DD
last_verified: YYYY-MM-DD
sources:
  - https://primary-source.example/
  - https://secondary-source.example/
authority: high | medium | community
status: current | draft | stale | deprecated
---
```

## Field-by-field

### `tags` (required, ≥ 1 entry)

Lowercase kebab-case keywords. The MCP search engine ranks against tag overlap heavier than against body text. Aim for 3–8 tags per file. Examples:

| Cheatsheet | Tags |
|---|---|
| `languages/java/rxjava-event-driven.md` | `[java, rxjava, async, event-driven, reactive-streams]` |
| `algorithms/binary-search.md` | `[algorithm, search, divide-and-conquer, sorted-arrays]` |
| `patterns/gof-observer.md` | `[design-pattern, gof, observer, event-driven, decoupling]` |

### `languages` (optional)

Language slugs the cheatsheet applies to. Empty array `[]` for language-agnostic content. Used by the MCP to filter context (e.g., "I'm in a Rust project, hide Java cheatsheets").

### `since` (required)

ISO-8601 date the cheatsheet was first written. Never changes.

### `last_verified` (required)

ISO-8601 date the cited sources were re-checked AND the content was confirmed accurate. Bumped only after re-verification — never blindly. Drives the staleness signal: > 90 days old = `status: stale`.

### `sources` (required, ≥ 1 entry)

The same URLs cited in the `## Provenance` markdown section. Repeated here for machine-parsing (the markdown section is for humans). The MCP server can `curl -fsSI` each URL to detect dead links.

### `authority` (required)

| Value | Meaning |
|---|---|
| `high` | Vendor docs, standards body, RFC, IETF, W3C, WHATWG, ISO. The cheatsheet's claims are directly from the source of truth. |
| `medium` | Recognised community project's own docs (postgresql.org, nginx.org, mozilla.org/MDN). Trustworthy but not the standards body. |
| `community` | Wikipedia, well-known textbook companions, project READMEs. Must be paired with at least one `high` source — never standalone. |

### `status` (required)

| Value | Use when | MCP behaviour |
|---|---|---|
| `current` | The file is fully verified and up to date. | Default — surfaced in normal search results. |
| `draft` | Authored but provenance not yet verified (e.g., the 60 legacy cheatsheets pre-methodology). | Surfaced with a warning; spec citations to it warn at validate time. |
| `stale` | `last_verified` is > 90 days old. | Surfaced with "may be out of date" hint. Refresh recommended. |
| `deprecated` | Kept for traceability under @tombstone retention; superseded by another cheatsheet. | Hidden by default; surfaced only with `?include=deprecated` flag. |

## YAML escaping reminders

- Tags / list items in flow style: `[a, b, c]`. Avoid trailing commas (YAML rejects).
- Multi-word values without quotes: fine if no special chars (`status: current`).
- Wrap in double-quotes if value contains `:`, `#`, `[`, `]`, `{`, `}`, `&`, `*`, `!`, `|`, `>`, `'`, `"`, `%`, `@`, `` ` ``.
- The Norway Problem still applies: ISO country codes that look like booleans (`NO`, `ON`, `OFF`) need quoting.

## See also

- `runtime/cheatsheet-architecture-v2.md` — the broader architecture
- `runtime/cheatsheet-shortcomings.md` — what this spec doesn't yet cover
- `languages/yaml.md` (DRAFT) — YAML basics

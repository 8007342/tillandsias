---
tags: [meta, cheatsheet-system, frontmatter, mcp, tier-system]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://yaml.org/spec/1.2.2/
  - https://jekyllrb.com/docs/front-matter/
  - https://spdx.org/licenses/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Cheatsheet frontmatter spec (v2)

@trace spec:cheatsheet-tooling, spec:cheatsheet-source-layer, spec:cheatsheets-license-tiered, spec:spec-traceability
@cheatsheet runtime/cheatsheet-architecture-v2.md

## Provenance

- YAML 1.2.2 spec: <https://yaml.org/spec/1.2.2/> — the syntax
- Jekyll's front matter convention (the prevailing markdown-with-YAML pattern): <https://jekyllrb.com/docs/front-matter/>
- SPDX license list: <https://spdx.org/licenses/> — canonical short-IDs used by the `license` field on per-cheatsheet declarations
- `openspec/specs/cheatsheets-license-tiered/spec.md` — normative authority for the v2 tier-related fields
- **Last updated:** 2026-04-27

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

## v2 — tier-related fields (cheatsheets-license-tiered)

The original schema (above) is unchanged. Three groups of new fields land on top:

### Tier classification (always present)

| Field | Type | Notes |
|---|---|---|
| `tier` | enum: `bundled` / `distro-packaged` / `pull-on-demand` | Validator infers from `cheatsheets/license-allowlist.toml` if omitted; safe default is `pull-on-demand` (never accidentally bundle an unaudited domain). |
| `summary_generated_by` | enum: `hand-curated` / `agent-generated-at-build` / `agent-generated-at-runtime` | How the summary above the provenance section was produced. |
| `bundled_into_image` | bool | True iff `tier in {bundled, distro-packaged}`. Convenience flag for fast filtering. |
| `committed_for_project` | bool | True iff this cheatsheet lives under `<project>/.tillandsias/cheatsheets/`. Default false. |

### Tier-conditional fields (presence MUST match `tier`)

| Field | Required when | Forbidden when |
|---|---|---|
| `image_baked_sha256` (hex SHA-256) | `tier == bundled` (set at forge build time) | other tiers |
| `structural_drift_fingerprint` (first 16 hex of SHA over `<h1>+<h2>+<h3>` outline) | `tier == bundled` (set at forge build time) | other tiers |
| `local` (absolute path inside the forge image) | `tier in (bundled, distro-packaged)` | `tier == pull-on-demand` (the pull cache path is per-project ephemeral, not author-knowable) |
| `package` (OS package name) | `tier == distro-packaged` | other tiers |
| `pull_recipe: see-section-pull-on-demand` (literal value) | `tier == pull-on-demand` | other tiers |

### CRDT override discipline (presence is a unit — all-three or none)

When a project-committed cheatsheet shadows a forge-bundled cheatsheet at the same path, four fields are required as a unit. The validator emits ERROR if any one is missing or empty when `shadows_forge_default` is set.

| Field | Type | What it states |
|---|---|---|
| `shadows_forge_default` | path string | The relative path of the forge-bundled cheatsheet being shadowed. |
| `override_reason` | multi-line string | "this project doesn't FOO because BAR" — the *why* |
| `override_consequences` | multi-line string | What affordability is given up by taking this path — the *cost* |
| `override_fallback` | multi-line string | What to do if the override conditions don't apply — the *recovery* |

This is the **CRDT override discipline** — meaning converges across replicas through structured discipline, not silent shadowing. See `runtime/cheatsheet-crdt-overrides.md` for the full pattern and the runtime banner contract.

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
  - `https://yaml.org/spec/1.2.2/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/yaml.org/spec/1.2.2/`
- **License:** see-license-allowlist
- **License URL:** https://yaml.org/spec/1.2.2/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/yaml.org/spec/1.2.2/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://yaml.org/spec/1.2.2/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/cheatsheet-frontmatter-spec.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `runtime/cheatsheet-architecture-v2.md` — the broader architecture
- `runtime/cheatsheet-tier-system.md` — the three tiers, when each applies, worked examples per tier
- `runtime/cheatsheet-pull-on-demand.md` — stub format for `tier: pull-on-demand`
- `runtime/cheatsheet-crdt-overrides.md` — project-committed shadow flow
- `runtime/cheatsheet-lifecycle.md` — convergence loop across all three tiers
- `runtime/cheatsheet-shortcomings.md` — what this spec doesn't yet cover
- `cheatsheets/license-allowlist.toml` — the tier classifier

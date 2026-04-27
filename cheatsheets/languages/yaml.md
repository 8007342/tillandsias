---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://yaml.org/spec/1.2.2/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# YAML

@trace spec:agent-cheatsheets

## Provenance

- YAML 1.2 specification revision 1.2.2 (2021-10-01): <https://yaml.org/spec/1.2.2/> — mappings, sequences, block scalars (|, >), block chomping (§8.1.1.2), flow collections (§7), anchors/aliases (§3.2.2.2), null/bool values, document separators, tabs-forbidden rule, type tags; also covers Norway Problem (yes/no/on/off as 1.1 booleans)
- **Last updated:** 2026-04-25

**Version baseline**: YAML 1.2 (most parsers default to 1.1 quirks; explicit `%YAML 1.2` directive recommended)
**Use when**: writing YAML config — Kubernetes, GitHub Actions, OpenAPI, CI files.

## Quick reference

| Construct | Syntax |
|---|---|
| Mapping (block) | `key: value` |
| Sequence (block) | `- item` |
| Mapping (flow) | `{key: value, k2: v2}` |
| Sequence (flow) | `[a, b, c]` |
| Nested mapping | child indented ≥ 1 space (2 by convention) under parent key |
| String (plain) | `name: alice` (no quotes when unambiguous) |
| String (single-quoted) | `'literal, no escapes except '''` |
| String (double-quoted) | `"escapes \n \t \" \\"` |
| Literal block | `key: \|` then indented lines (newlines preserved) |
| Folded block | `key: >` then indented lines (newlines → spaces) |
| Block chomping | `\|-` strip trailing newlines, `\|+` keep all, `\|` keep one |
| Null | `null`, `~`, or empty value |
| Bool | `true` / `false` (1.2); `yes`/`no`/`on`/`off` are 1.1 quirks |
| Anchor / alias | `&name` defines, `*name` references |
| Merge key | `<<: *anchor` (1.1 extension; widely supported) |
| Document separator | `---` (start), `...` (end, optional) |
| Comment | `# to end of line` (block style only) |
| Type tag | `!!str 12345`, `!!binary <base64>` |

Indentation is **spaces only**. Tabs are forbidden inside structure (allowed inside scalars).

## Common patterns

### Anchors and aliases — DRY config

```yaml
defaults: &defaults
  timeout: 30
  retries: 3

job_a:
  <<: *defaults
  name: build

job_b:
  <<: *defaults
  name: test
  retries: 5  # override
```

`&defaults` defines an anchor; `*defaults` references it; `<<:` merges its keys (later keys win).

### Multi-document file

```yaml
---
kind: ConfigMap
metadata: {name: app-config}
---
kind: Secret
metadata: {name: app-secret}
```

`kubectl apply -f` and most YAML loaders iterate documents. Use `yaml.safe_load_all()` in Python.

### Multi-line strings — pick the right indicator

```yaml
literal: |
  line one
  line two
folded: >
  this becomes
  one long line
stripped: |-
  no trailing newline
```

`|` preserves newlines (scripts, certs). `>` folds to spaces (prose). Add `-` to strip trailing newline.

### Flow style for short, dense data

```yaml
matrix:
  os: [ubuntu, macos, windows]
  python: ["3.11", "3.12", "3.13"]
env: {DEBUG: "1", LOG_LEVEL: info}
```

Use flow inside block, never the reverse. Comments are not allowed inside flow collections.

### Force string type when value looks numeric/boolean

```yaml
version: "3.10"        # without quotes -> float 3.1
zip_code: "01234"      # without quotes -> int 1234 (lost zero)
country: "NO"          # without quotes -> false (Norway problem)
```

## Common pitfalls

- **The Norway Problem** — `country: NO` parses as `false` under YAML 1.1. Two-letter country codes (`NO`, `NY`) and stock tickers (`ON`, `OFF`) must be quoted. YAML 1.2 fixes this, but most parsers still default to 1.1 boolean rules.
- **Tab indentation forbidden** — tabs anywhere in structure throw a parse error. Editors that auto-convert to tabs silently break files. Configure 2-space indent and visualize whitespace.
- **Indentation of keys after a mapping value** — sibling keys must align with the parent key, not its value. `foo:\n  bar: 1\nbaz: 2` makes `baz` a sibling of `foo`; indenting `baz` two spaces makes it a sibling of `bar`.
- **Leading-zero numbers parse as octal (1.1) or decimal (1.2)** — `time: 08:00` may fail (8 is not octal-valid) or be misread. Quote times, version strings, and zero-padded IDs.
- **Trailing whitespace in block scalars** — extra spaces after `|` or `>` change the indentation indicator and break parsing. Strip trailing whitespace on save.
- **Comments inside flow collections** — `[a, # bad, b]` is a parse error. Comments are only valid in block style or between flow tokens on their own line.
- **`%YAML 1.2` directive scope** — the directive applies only to the document immediately following it. In multi-doc files, repeat it before each `---` to keep 1.2 rules consistent.
- **Duplicate keys silently override (1.1) or error (1.2 strict)** — a typo that repeats a key may overwrite without warning. Run `yamllint` to catch.
- **Anchors cross document boundaries** — `*alias` from doc 1 cannot be referenced in doc 2. Each `---` starts a fresh anchor scope.
- **`null` vs empty string** — `key:` (no value) is `null`; `key: ""` is empty string. Templating systems that check truthiness behave differently for each.
- **Merge keys (`<<:`) are non-standard** — formally a 1.1 extension; some 1.2 parsers (notably go-yaml v3) drop them. Check your loader's behavior before relying on `<<:`.

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
   cheatsheet at `<project>/.tillandsias/cheatsheets/languages/yaml.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/yq.md` — primary CLI for YAML manipulation (jq-like, `yq -i`, `yq -P`)
- `languages/json.md` — JSON is a strict subset of YAML 1.2; flow style ≈ JSON
- `languages/toml.md` — sister config format with stricter typing and no indentation traps

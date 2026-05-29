---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://jqlang.org/manual/
  - https://github.com/jqlang/jq
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# jq

@trace spec:agent-cheatsheets

**Version baseline**: jq 1.7 (Fedora 43 package).
**Use when**: querying or transforming JSON in the forge — pipelines, log triage, config introspection, agent tool plumbing.

## Provenance

- jq official manual (jqlang.org): <https://jqlang.org/manual/> — complete language and flag reference (jq 1.8 as of 2026-04-25)
- jq GitHub repository: <https://github.com/jqlang/jq> — release notes and source
- **Last updated:** 2026-04-25

Verified against the official jq 1.8 manual: `select(f)` produces input unchanged when true and no output when false (confirmed); `-r` strips quotes from string results (confirmed); `-s` slurps into array (confirmed); `--arg` passes string, `--argjson` passes JSON (confirmed); `group_by`, `to_entries`/`from_entries` confirmed. Version note: Fedora 43 ships jq 1.7; the manual cited is 1.8 — all constructs listed here are present in both.

## Quick reference

| Construct | Effect |
|-----------|--------|
| `.` | Identity — emit input unchanged |
| `.foo` / `.["foo"]` | Object field; bracket form needed for special keys |
| `.foo?` | Optional field — `null` instead of error if missing or wrong type |
| `.[]` | Iterate array (or object values); emits one value per element |
| `.[2]`, `.[-1]` | Array index (negative counts from end) |
| `.[2:5]` | Array / string slice |
| `..` | Recursive descent — every sub-value |
| `a \| b` | Pipe — feed `a`'s output into `b` |
| `a, b` | Comma — emit both `a` and `b` |
| `length`, `keys`, `values`, `type`, `has("k")`, `in(obj)` | Introspection builtins |
| `map(f)` ≡ `[.[] \| f]` | Map over array |
| `select(cond)` | Drop values where `cond` is false / null |
| `group_by(f)`, `sort_by(f)`, `unique_by(f)` | Reshape arrays by key function |
| `to_entries` / `from_entries` | Object ⇄ `[{key, value}, …]` |
| `add` | Sum numbers / concat arrays / merge objects |
| `-r` | Raw output (strip JSON quotes from string results) |
| `-c` | Compact output (one value per line — NDJSON shape) |
| `-s` | Slurp — read whole input stream into one array |
| `-n` | Null input — start from `null` (use with `inputs`) |
| `--arg k v`, `--argjson k v` | Pass shell value as `$k` (string vs JSON) |

## Common patterns

### Filter with a predicate
```bash
jq '.events[] | select(.level == "error" and .spec == "forge-launch")' log.json
```
`select` is the workhorse — combine with `and`/`or`/`not`, regex (`test("…")`), or `contains(…)`.

### Group and aggregate
```bash
jq 'group_by(.spec) | map({spec: .[0].spec, count: length})' events.json
```
`group_by` returns an array of arrays; reshape with `map({…})`. Use `add` or `length` for totals.

### Slurp NDJSON + inject shell value
```bash
jq -s --argjson cutoff 100 '[.[] | select(.duration_ms > $cutoff)]' events.ndjson
```
`-s` turns one-value-per-line into a single array. `--argjson` parses the value as JSON (numbers, bools); `--arg` keeps it a string.

### Recursive descent — find every match anywhere
```bash
jq '.. | objects | select(has("token"))' config.json
```
`..` walks every sub-value; `objects` keeps only object-typed ones (a common idiom — `..` alone emits scalars too).

### Raw output for shell scripting
```bash
for img in $(jq -r '.images[].name' manifest.json); do
  podman pull "$img"
done
```
Without `-r`, strings come out quoted (`"foo"`) and break shell loops. Pair `-r` with simple string-emitting filters; for structured data use `-c` and parse line-by-line.

## Common pitfalls

- **Trailing newline on every output** — jq always appends `\n`. When piping into something that counts bytes (hashing, `Content-Length`), use `tr -d '\n'` or `printf %s "$(jq …)"`.
- **`-r` only strips quotes from string results** — `jq -r '.count'` still prints `42` (it's a number, not a quoted string). The flag does nothing for objects/arrays — they print as compact JSON either way.
- **Missing keys error without `?`** — `.foo.bar` on `{"foo": null}` raises `Cannot index null with "bar"`. Use `.foo?.bar?` or `.foo // {} | .bar` to tolerate gaps. Only do this when absence is genuinely OK; silencing real bugs is worse than crashing.
- **`null` vs missing is invisible by default** — `select(.x)` drops both `null` and `false`. To keep explicit `null`, use `select(has("x"))` or `select(.x != "absent_sentinel")`.
- **NaN / Infinity round-trip badly** — jq parses `NaN` and `Infinity` (extension), but emits them as `null` (since RFC 8259 forbids them). A pipeline `jq . | jq .` silently loses non-finite floats.
- **NDJSON requires `-s` or `inputs`, not `.`** — `jq '.foo' file.ndjson` only sees the first line; the rest are syntax errors. Use `jq -s '.[].foo'` (load all) or `jq -n '[inputs | .foo]'` (stream — better for huge files).
- **`group_by` / `sort_by` need comparable keys** — mixing types (numbers and strings under the same key) raises `… and string cannot be sorted`. Coerce first: `group_by(.id | tostring)`.
- **Large integers lose precision** — jq stores numbers as doubles. IDs above `2^53 - 1` (`9007199254740991`) round. For 64-bit IDs, keep them as strings end-to-end (`--arg`, not `--argjson`).
- **`*` merge replaces arrays** — `{a:[1]} * {a:[2]}` ⇒ `{a:[2]}`, not `{a:[1,2]}`. Write a recursive helper if you need array concat.
- **Single-quote your filter in shell** — double quotes let `$` and backticks expand inside the filter, mangling jq variables (`$x`) into shell ones. Use single quotes; pass shell data via `--arg` / `--argjson`.

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
  - `https://jqlang.org/manual/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/jqlang.org/manual/`
- **License:** see-license-allowlist
- **License URL:** https://jqlang.org/manual/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/jqlang.org/manual/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://jqlang.org/manual/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/jq.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/yq.md` — same query model for YAML (Mike Farah's `yq` ports jq syntax)
- `languages/json.md` — JSON format reference (escapes, NDJSON, integer limits)

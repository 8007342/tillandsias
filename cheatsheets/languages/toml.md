---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://toml.io/en/v1.0.0
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# TOML

@trace spec:agent-cheatsheets

## Provenance

- TOML 1.0 specification (official): <https://toml.io/en/v1.0.0> — defines key/value pairs, tables, nested tables, dotted keys, inline tables (no trailing comma), arrays (trailing comma OK), array of tables ([[...]]), multi-line strings, datetime types, integer/float literals, 64-bit signed integer range
- **Last updated:** 2026-04-25

**Version baseline**: TOML 1.0
**Use when**: writing config the agent encounters in `Cargo.toml`, `pyproject.toml`, `tauri.conf.json`-adjacent tooling, or `~/.config/tillandsias/config.toml`.

## Quick reference

| Concept | Syntax |
|---|---|
| Key/value | `key = "value"` (one per line, no commas) |
| Bare key | `key`, `bare_key`, `bare-key`, `1234` |
| Quoted key | `"127.0.0.1" = "ip"` (when it contains `.` or special chars) |
| Table | `[server]` then `host = "x"` |
| Nested table | `[server.tls]` |
| Dotted key | `server.tls.cert = "x"` (equivalent to nested table) |
| Inline table | `point = { x = 1, y = 2 }` (single-line, no trailing comma) |
| Array | `ports = [80, 443]` (multi-line allowed, trailing comma OK) |
| Array of tables | `[[products]]` repeated for each item |
| String | `"basic"`, `'literal'` (no escapes), `"""multi"""`, `'''multi'''` |
| Integer | `42`, `1_000`, `0xFF`, `0o755`, `0b1010` (64-bit signed) |
| Float | `3.14`, `1e10`, `inf`, `nan` (IEEE 754 binary64) |
| Bool | `true` / `false` (lowercase) |
| Datetime | `1979-05-27T07:32:00Z`, `1979-05-27T07:32:00`, `1979-05-27`, `07:32:00` |
| Comment | `# to end of line` |

## Common patterns

### Tables vs dotted keys (equivalent)

```toml
# Style A — table header
[server.tls]
cert = "/etc/tls.pem"
key  = "/etc/tls.key"

# Style B — dotted keys
server.tls.cert = "/etc/tls.pem"
server.tls.key  = "/etc/tls.key"
```
Both produce the same parsed structure. Pick one per file and stick with it.

### Array of tables — list of structs

```toml
[[products]]
name = "Hammer"
sku  = 738594937

[[products]]
name = "Nail"
sku  = 284758393
color = "gray"
```
Each `[[products]]` appends a new table to the `products` array. Use this for lists where each element has multiple fields.

### Multi-line strings

```toml
description = """
Line one.
Line two — backslash at end \
joins lines without newline.
"""

regex = '''C:\Users\bin\.*\.exe'''   # literal: no escapes processed
```
Triple-quoted strings strip the leading newline if it's the first character. Use literal (`'''`) for regex/Windows paths.

### Datetime literals (first-class, not strings)

```toml
created_at = 2026-04-25T14:30:00Z       # offset datetime (UTC)
local_dt   = 2026-04-25T14:30:00        # local datetime (no offset)
local_date = 2026-04-25                  # local date
local_time = 14:30:00                    # local time
```
Parsers expose these as native datetime types. Don't quote them.

### Inline table for compact records

```toml
point  = { x = 1, y = 2 }
author = { name = "Ada", email = "ada@example.com" }
```
Inline tables must fit on one line. No trailing comma. For longer records, switch to `[table]` style.

## Common pitfalls

- **Tables vs dotted keys equivalence** — `[a.b]` then `c = 1` is the same as `a.b.c = 1`. Mixing styles in the same file confuses both humans and linters.
- **Tables-after-keys break parsing** — once a `[table]` header appears, all subsequent bare keys belong to that table. You cannot "go back" to the root namespace except by declaring it explicitly with another `[other_table]`.
- **Redefining a table is a hard error** — declaring `[a]` twice (or `[a]` then `a.x = 1` later in dotted form) is rejected. TOML 1.0 forbids out-of-order table assembly.
- **Inline tables are immutable** — `point = { x = 1 }` then later `point.y = 2` is invalid. Inline tables must be fully defined in their literal.
- **No trailing comma in inline tables** — `{ x = 1, y = 2, }` is a syntax error. Arrays allow trailing commas, inline tables do not.
- **Integer overflow (64-bit signed)** — values must fit in `i64` (`-2^63` to `2^63-1`). Larger numbers (e.g. nanosecond timestamps past year 2262) silently misparse or reject.
- **Datetimes are first-class, not strings** — `created = "2026-04-25"` gives you a string; `created = 2026-04-25` gives you a date. Quoting changes the type.
- **Bare keys are case-sensitive** — `Name` and `name` are different keys. TOML does not normalize.
- **Float vs integer** — `1` is an int, `1.0` is a float. They are not interchangeable; some parsers reject implicit coercion.
- **Hex/octal/binary are integers only** — `0xFF` works for ints, but there's no `0x1.8p+1` float literal.
- **Heterogeneous arrays are allowed in TOML 1.0** — `[1, "two", 3.0]` parses, but many consumers (serde, Cargo) reject them. Stick to homogeneous arrays in practice.

## TOML vs YAML vs JSON

| Trait | TOML | YAML | JSON |
|---|---|---|---|
| Comments | yes (`#`) | yes (`#`) | no |
| Syntax rigidity | strict, explicit types | indentation-significant, type guessing | strict, no comments |
| Common use case | config files (Cargo, pyproject, tillandsias) | k8s/CI manifests, Ansible | data interchange, APIs |

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
  - `https://toml.io/en/v1.0.0`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/toml.io/en/v1.0.0`
- **License:** see-license-allowlist
- **License URL:** https://toml.io/en/v1.0.0

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/toml.io/en/v1.0.0"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://toml.io/en/v1.0.0" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/languages/toml.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `languages/yaml.md`, `languages/json.md`
- `build/cargo.md` — `Cargo.toml` schema specifics

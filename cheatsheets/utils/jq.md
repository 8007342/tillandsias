# jq

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: jq 1.7 (Fedora 43 package).
**Use when**: querying or transforming JSON in the forge — pipelines, log triage, config introspection, agent tool plumbing.

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

## See also

- `utils/yq.md` — same query model for YAML (Mike Farah's `yq` ports jq syntax)
- `languages/json.md` — JSON format reference (escapes, NDJSON, integer limits)

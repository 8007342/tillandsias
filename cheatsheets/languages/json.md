# JSON

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: JSON per RFC 8259. JSON Lines and JSON Pointer (RFC 6901) covered briefly.
**Use when**: producing or consuming JSON in the forge — config files, API payloads, jq targets.

## Quick reference

| Construct | Syntax |
|-----------|--------|
| Object | `{"key": "value", "n": 1}` |
| Array | `[1, 2, 3]` |
| String | `"text"` (double quotes only, UTF-8) |
| Number | `42`, `-1.5`, `2.5e10` (no leading `+`, no leading zero, no `NaN`/`Infinity`) |
| Boolean | `true`, `false` (lowercase) |
| Null | `null` (lowercase) |
| Escape | `\"`, `\\`, `\n`, `\t`, `\r`, `\b`, `\f`, `\/`, `\uXXXX` |
| Root value | Any value — object, array, string, number, bool, null |

**Not allowed**: trailing commas, comments (`//` or `/* */`), single quotes, unquoted keys, hex literals (`0xFF`), `undefined`, `NaN`, `Infinity`, multi-line strings.

**Sibling formats**:
- **JSON Lines (NDJSON)** — one JSON value per line, no enclosing array. Streaming-friendly.
- **JSON Pointer** (RFC 6901) — `/foo/0/bar` addresses `data.foo[0].bar`. `~0` escapes `~`, `~1` escapes `/`.
- **JSON5 / HJSON** — relaxed supersets allowing comments and trailing commas. **Not** real JSON; most parsers reject them.

## Common patterns

### Pretty-print, validate, minify
```bash
jq . file.json                      # pretty-print + validate
jq -c . file.json                   # minify (compact, one line)
jq empty file.json && echo OK       # validate without printing
python3 -m json.tool file.json      # stdlib fallback (no jq)
```

### Stream JSON Lines
```bash
jq -c '. | select(.level == "error")' events.ndjson  # filter NDJSON
jq -s '.' events.ndjson                              # slurp NDJSON into array
jq -c '.[]' array.json > out.ndjson                  # array -> NDJSON
```
`-c` writes one compact value per line (preserves NDJSON shape). `-s` slurps the whole stream.

### JSON Pointer lookup
```bash
jq 'getpath(["users", 0, "name"])' file.json   # path-style
# Pointer "/users/0/name" -> jq path ["users", 0, "name"]
```
Use Pointer when an external spec (JSON Schema, JSON Patch) references nodes; convert `/a/b/0` to `["a", "b", 0]` for jq.

### Deep merge two objects
```bash
jq -s '.[0] * .[1]' base.json override.json     # shallow-ish merge
jq -s 'reduce .[] as $x ({}; . * $x)' a.json b.json c.json
```
`*` recursively merges objects but **replaces** arrays. Write a recursive helper if you need array concat.

### Schema validation (when correctness matters)
```bash
# JSON Schema validators (install per project, not in forge by default):
#   python: jsonschema, check-jsonschema
#   node:   ajv-cli
check-jsonschema --schemafile schema.json data.json
```
Only reach for a schema validator when the payload crosses a trust boundary (API input, config from a user). For internal IPC, `postcard` (binary, schema-by-type) is preferred — see project conventions.

## Common pitfalls

- **Trailing commas** — `[1, 2, 3,]` and `{"a": 1,}` are syntax errors. Lints (and humans) miss this; run `jq empty` in CI.
- **Comments rejected** — `//` and `/* */` are not JSON. If you need comments, use TOML or YAML, or strip them with a preprocessor (`jq` will refuse the file).
- **Single quotes rejected** — `{'a': 1}` is invalid. Always double quotes for both keys and strings.
- **`NaN`, `Infinity`, `-Infinity` rejected** — RFC 8259 has no representation for non-finite floats. Some lax parsers (Python's `json` with `allow_nan=True`) emit them; canonical JSON cannot read them back. Encode as `null` or a string sentinel.
- **Integer precision** — JSON numbers have no max, but JavaScript and many parsers store them as IEEE-754 doubles (53-bit mantissa). Anything above `2^53 - 1` (`9007199254740991`) silently loses precision. For 64-bit IDs, send strings.
- **Duplicate keys are undefined** — RFC 8259 says behaviour is implementation-defined. Most parsers keep the last; some keep the first; some error. Never produce duplicates.
- **Key ordering is not preserved by spec** — objects are unordered. If you need deterministic output (diffs, hashing, signatures), sort keys: `jq -S . file.json`.
- **UTF-8 BOM** — RFC 8259 forbids leading BOM. Some Windows tools write one; strip with `sed -i '1s/^\xEF\xBB\xBF//' file.json` or `dos2unix`.
- **`null` vs missing key** — `{"a": null}` and `{}` are different. Many APIs treat them as the same; many don't. Document which your producer/consumer sends.
- **Pretty-printing inflates size 3-5x** — for logs and IPC, always emit compact (`jq -c`, `json.dumps(x, separators=(',', ':'))`). Pretty-print only for human eyes.

## See also

- `utils/jq.md` — primary CLI for JSON manipulation, filtering, transformation
- `languages/yaml.md` — config-friendly sibling (comments, multi-line strings)
- `languages/toml.md` — preferred for Tillandsias user config (typed, comment-friendly)
- `runtime/forge-container.md` — why `postcard` (not JSON) for hot-path IPC inside the enclave

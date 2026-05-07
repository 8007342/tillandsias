---
tags: [jq, yq, json, yaml, transform]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://stedolan.github.io/jq/
  - https://mikefarah.gitbook.io/yq/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# jq and yq

@trace spec:agent-source-of-truth

**Version baseline**: jq 1.7.1, yq 4.40.5 (Fedora 43)  
**Use when**: Querying, filtering, or transforming JSON (jq) or YAML (yq) from command line or pipes

## Provenance

- https://stedolan.github.io/jq/ — jq manual (canonical reference)
- https://mikefarah.gitbook.io/yq/ — yq documentation
- **Last updated:** 2026-04-27

## Quick reference

| Task | jq | yq |
|------|----|----|
| Pretty-print | `jq '.'` | `yq '.'` |
| Extract field | `jq '.key'` | `yq '.key'` |
| Array element | `jq '.[0]'` | `yq '.[0]'` |
| Filter array | `jq '.[] \| select(.id == 1)'` | `yq '.[] \| select(.id == 1)'` |
| Map transform | `jq 'map(.name)'` | `yq 'map(.name)'` |
| Conditional | `jq 'if .status == "ok" then .data else empty end'` | `yq 'if .status == "ok" then .data else empty end'` |
| From stdin | `cat file.json \| jq '.'` | `cat file.yaml \| yq '.'` |
| Raw output | `jq -r '.text'` (no quotes) | `yq -r '.text'` |
| Count items | `jq 'length'` or `jq '[.items[]] \| length'` | `yq 'length'` |

## Common patterns

**Extract and pretty-print fields:**
```bash
curl https://api.example.com/users | jq '.users[] | {id, name, email}'
```

**Filter by condition and count:**
```bash
jq '[.items[] | select(.status == "active")] | length' data.json
```

**Merge multiple JSON objects:**
```bash
jq -s 'add' file1.json file2.json
```

**Transform YAML to JSON:**
```bash
yq -o=json '.' config.yaml > config.json
```

**Conditional field assignment:**
```bash
jq '.items[] |= if .price then .total = .price * .qty else . end' data.json
```

**Group and aggregate:**
```bash
jq 'group_by(.category) | map({category: .[0].category, count: length})' items.json
```

## Common pitfalls

- **String vs number**: Unquoted `1` is number; `"1"` is string. Use `tonumber` or `tostring`.
- **Null propagation**: `.a.b.c` returns `null` if any level missing (doesn't error). Use `try ... catch` for safety.
- **Array vs object**: `.[]` on object yields values, not keys. Use `to_entries` to preserve structure.
- **Raw output confusion**: `-r` strips JSON quotes. Without it, output is JSON-encoded. Use for CSV.
- **Slicing edge case**: `.[:2]` works on arrays/strings; on objects returns `null`.
- **Empty output**: `.[] | select(.id == 999)` returns nothing on no match (not `null`).
- **yq path syntax**: `yq '.["key-with-dash"]'` for special chars; `.key-with-dash` doesn't work.

## See also

- `languages/json.md` — JSON syntax, pitfalls, JSON Lines
- `languages/yaml.md` — YAML indentation, anchors, common pitfalls

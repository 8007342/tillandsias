---
tags: [lua, scripting, text-editing, merge-conflicts, forge-tooling]
languages: [lua]
since: 2026-10-31
last_verified: 2026-10-31
sources:
  - https://www.lua.org/manual/5.4/
  - https://lunarmodules.github.io/luafilesystem/manual.html
  - https://www.inf.puc-rio.br/~roberto/lpeg/
authority: vendor
status: active

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Lua

@trace spec:agent-cheatsheets, spec:default-image

## Provenance

- Lua 5.4 Reference Manual: <https://www.lua.org/manual/5.4/> — string library (§6.4: `string.find` with `plain=true`, `gsub` pattern magic characters `^$()%.[]*+-?`), `io.open`/`file:read("a")` (§6.8), `os.rename` (§6.9), integer division `//` (§3.4.1)
- LuaFileSystem manual: <https://lunarmodules.github.io/luafilesystem/manual.html> — `lfs.dir`, `lfs.attributes`, `lfs.mkdir`
- LPeg: <https://www.inf.puc-rio.br/~roberto/lpeg/> — parsing expression grammars for structured text
- **Last updated:** 2026-10-31

## In this forge

`lua` is Lua 5.4 from Fedora, with `lfs` (lua-filesystem) and `lpeg` (lua-lpeg)
installed. Reach for it, or for the two helpers below, instead of a python3
heredoc: python3 is forbidden for committed automation (`methodology.yaml` →
`tlatoani_hard_no_python`).

### `lua-edit` — batched, asserted literal replace

```bash
lua-edit path/to/file 'old one' 'new one' 'old two' 'new two'
```

Every OLD must occur **exactly once** in the file as read. If any occurs zero
or several times, nothing is written, the exit is 1, and each failing pair is
named. On success all pairs apply and the file is replaced atomically.
Matching is literal: `.` `%` `(` mean themselves. Multi-line strings work with
`$'line one\nline two'`.

### `lua-conflict` — resolve merge-conflict hunks

```bash
lua-conflict path/to/file ours      # every hunk keeps the side before =======
lua-conflict path/to/file theirs 2  # only hunk 2 keeps the side after it
lua-conflict path/to/file both      # ours, then theirs
git add path/to/file
```

A diff3 base section (`|||||||` up to `=======`) is dropped. No hunk, an
unterminated hunk or an out-of-range HUNK exits 1 and changes nothing.

## Pitfalls

- `string.find(s, x)` and `string.gsub` treat `x` as a **pattern**. For a
  literal match pass `plain=true`: `s:find(x, 1, true)`. `gsub` has no plain
  mode; escape with `x:gsub("%p", "%%%0")` or use `lua-edit`.
- `#t` is only defined for sequences; a table with holes gives any border.
- Strings are bytes. `#s` counts bytes, not characters; use `utf8.len(s)`.
- `io.open` returns `nil, err` instead of raising; check it.

## Pull on Demand

> The interpreter and both helpers are bundled in the forge image; only the
> manual is not. Materialize it into the per-project pull cache when you need
> depth beyond the summary above. The proxy (HTTP_PROXY=http://proxy:3128)
> handles the fetch.

### Source

- **Upstream URL(s):**
  - `https://www.lua.org/manual/5.4/manual.html`
- **Archive type:** `single-html`
- **Expected size:** `~0.4 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.lua.org/manual/5.4/manual.html`
- **License:** see-license-allowlist
- **License URL:** https://www.lua.org/license.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.lua.org/manual/5.4/manual.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://www.lua.org/manual/5.4/manual.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the section relevant to your project.
2. If the project leans on it heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/languages/lua.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

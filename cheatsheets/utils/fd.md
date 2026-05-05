---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://github.com/sharkdp/fd
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# fd (fd-find)

@trace spec:agent-cheatsheets

**Version baseline**: fd 9.x (Fedora package `fd-find`; binary is `fd`).
**Use when**: finding files in the forge — replacement for `find` with faster defaults.

## Provenance

- fd GitHub repository (sharkdp/fd) — README and flag reference: <https://github.com/sharkdp/fd> — authoritative source for all flags and default behaviours
- **Last updated:** 2026-04-25

Verified: default pattern mode is regex (not glob); `-g` switches to glob; `-H` includes hidden files; `-I` bypasses `.gitignore`; `-u` = `-HI`; placeholder tokens `{}`, `{/}`, `{//}`, `{.}`, `{/.}` confirmed for `-x`.

## Quick reference

| Op | Command | Notes |
|----|---------|-------|
| Basic search | `fd <pattern>` | Regex against filename, recursive from `.` |
| Glob mode | `fd -g '*.rs'` | Treat pattern as glob, not regex |
| Type filter | `fd -t f` / `-t d` / `-t l` / `-t x` | file / dir / symlink / executable |
| By extension | `fd -e rs -e toml` | Repeat `-e` for multiple extensions |
| In a path | `fd <pattern> <path>` | Limit search root |
| Hidden | `fd -H <pattern>` | Include dotfiles/dotdirs |
| Ignore-bypass | `fd -I <pattern>` / `--no-ignore` | Ignore `.gitignore` rules |
| Unrestricted | `fd -u <pattern>` | `-HI` shorthand (hidden + no-ignore) |
| Depth | `fd -d 3 <pattern>` | Max recursion depth |
| Exclude | `fd -E target -E node_modules` | Skip globs |
| Exec per-file | `fd <pattern> -x <cmd> {}` | Parallel, one process per match |
| Exec batched | `fd <pattern> -X <cmd>` | Single process, all matches as args |
| Case | `fd <pattern>` is smart-case | Add `-s` for strict, `-i` for force-insensitive |
| Absolute paths | `fd -a <pattern>` | Print full paths |

## Common patterns

### Find Rust source files

```bash
fd -t f -e rs
```

All `.rs` regular files under cwd, respecting `.gitignore`.

### Run a command per match (parallel)

```bash
fd -t f -e md -x wc -l {}
```

Runs `wc -l` once per file in parallel. `{}` is the path; `{/}`, `{//}`, `{.}`, `{/.}` give basename, dirname, no-ext, basename-no-ext.

### Batch all matches into one invocation

```bash
fd -t f -e rs -X rustfmt
```

Calls `rustfmt file1.rs file2.rs ...` exactly once. Use `-X` (uppercase) when the tool already accepts many args.

### Find hidden config files

```bash
fd -H -t f '^\.env'
```

Without `-H`, dotfiles like `.env` are skipped by default.

### Search ignoring `.gitignore`

```bash
fd -u target
```

Equivalent to `fd -HI target` — finds matches inside `target/`, `node_modules/`, etc.

## Common pitfalls

- **Pattern is regex, not glob** — `fd '*.rs'` matches literally nothing useful. Use `fd '\.rs$'`, or `fd -g '*.rs'`, or `fd -e rs`.
- **`.gitignore` is respected by default** — fd silently skips ignored paths. If a file you expect is missing, retry with `-I` (or `-u` for hidden+ignored). This bites hardest inside `target/` and `node_modules/`.
- **Dotfiles hidden by default** — `.env`, `.github/`, `.tillandsias/` are invisible without `-H`. Combine with `-I` (or use `-u`) when chasing config files inside ignored dirs.
- **`-x` runs in parallel** — output from concurrent commands can interleave; ordering is non-deterministic. Use `-X` for tools that need a stable single invocation, or pipe through `sort` after.
- **`-x` vs `-X` confusion** — lowercase `-x` = one process per file (parallel); uppercase `-X` = one process for all files (batched). Picking the wrong one is either slow (per-file `rustfmt`) or wrong (batched `rm -i` won't prompt sanely).
- **No symlink following by default** — `fd -L <pattern>` to traverse symlinked dirs. Without `-L`, fd lists symlinks but does not descend into them.
- **Smart-case surprises** — `fd README` is case-insensitive (no uppercase pattern), but `fd Readme` becomes case-sensitive. Force with `-i` or `-s` when scripting.
- **Binary name clash** — on Debian/Ubuntu the package is `fd-find` and the binary is `fdfind` (because of a name collision); on Fedora it's `fd`. The forge image uses Fedora, so `fd` works.

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
  - `https://github.com/sharkdp/fd`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/sharkdp/fd`
- **License:** see-license-allowlist
- **License URL:** https://github.com/sharkdp/fd

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/sharkdp/fd"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://github.com/sharkdp/fd" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/fd.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/ripgrep.md` — content search (fd finds files, rg searches inside them)
- `utils/git.md` — `.gitignore` rules that fd honors by default

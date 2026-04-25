# fd (fd-find)

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: fd 9.x (Fedora package `fd-find`; binary is `fd`).
**Use when**: finding files in the forge — replacement for `find` with faster defaults.

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

## See also

- `utils/ripgrep.md` — content search (fd finds files, rg searches inside them)
- `utils/git.md` — `.gitignore` rules that fd honors by default

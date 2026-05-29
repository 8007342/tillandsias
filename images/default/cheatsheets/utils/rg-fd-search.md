---
tags: [ripgrep, fd, search, cli, files]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://github.com/BurntSushi/ripgrep
  - https://github.com/sharkdp/fd
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# ripgrep and fd

@trace spec:agent-source-of-truth

**Version baseline**: ripgrep 14.1.0, fd 10.0.0 (Fedora 43)  
**Use when**: Searching code/files (ripgrep) or finding files by name/pattern (fd)

## Provenance

- https://github.com/BurntSushi/ripgrep — ripgrep documentation (canonical reference)
- https://github.com/sharkdp/fd — fd documentation
- **Last updated:** 2026-04-27

## Quick reference

| Task | ripgrep | fd |
|------|---------|-----|
| Search text | `rg 'pattern'` | N/A |
| Case-insensitive | `rg -i 'pattern'` | N/A |
| Search in type | `rg -t rust 'pattern'` | N/A |
| Count matches | `rg -c 'pattern'` | N/A |
| Find file | N/A | `fd 'pattern'` |
| Find by extension | N/A | `fd -e rs` |
| Case-insensitive find | N/A | `fd -i 'pattern'` |
| Type filter | N/A | `fd -t f` (file) or `-t d` (dir) |
| Follow symlinks | `rg -L` | `fd -L` |
| Exclude pattern | `rg --glob '!node_modules'` | `fd --exclude 'node_modules'` |
| Hidden files | `rg -u` (all) | `fd -H` |

## Common patterns

**Search for function definitions:**
```bash
rg 'fn [a-z_]+\(' --type rust    # Rust functions
rg '^\s*def ' --type python      # Python functions
```

**Find and replace in batch:**
```bash
fd -e rs | xargs sed -i 's/old_name/new_name/g'
rg 'old_name' --type rust -r 'new_name' --dry-run
```

**Find files modified in last 7 days:**
```bash
fd -m -7d       # Modified within 7 days
fd -c -7d       # Created within 7 days
```

**Search excluding common dirs:**
```bash
rg 'pattern' --glob '!node_modules' --glob '!vendor'
fd 'pattern' --exclude node_modules --exclude vendor
```

**Find large files:**
```bash
fd -S +10m     # Larger than 10 MiB
fd -S -100k    # Smaller than 100 KiB
```

## Common pitfalls

- **Regex vs literal**: rg treats input as regex. Use `-F` for literal strings.
- **Type filtering confusion**: `rg -t rust` filters by registered extension, not shebang. See `rg --type-list`.
- **Symlink following**: Both skip symlinks by default. Use `-L` to follow.
- **Hidden files by default**: rg and fd skip dot-files. Use `rg -u -u` (twice) or `fd -H`.
- **Path vs name**: `fd 'name'` matches within full path. Use `--path-separator=/` for cross-platform consistency.
- **Empty results**: Both exit silently with no matches (exit code 1). Wrap with `|| echo "not found"`.

## See also

- `utils/fzf-picker.md` — Fuzzy finding and integration with rg/fd
- `languages/bash.md` — Pipes, process substitution, xargs

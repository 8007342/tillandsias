# tree

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: tree 2.x (Fedora 43 package; current 2.1+).
**Use when**: visualising directory hierarchy — quick structural overview, sharing layout in docs/PRs, auditing what's in a folder before a `rm -rf`.

## Quick reference

| Op | Command | Notes |
|----|---------|-------|
| Limit depth | `tree -L <n>` | `n=1` is one level; default is unlimited |
| Dirs only | `tree -d` | Hide files, show structure only |
| Exclude pattern | `tree -I '<glob>'` | Pipe-separate: `-I 'target\|node_modules\|.git'` |
| Include only | `tree -P '<glob>'` | Whitelist files matching glob |
| Match dirs too | `tree -P '<glob>' --matchdirs` | Otherwise `-P` filters files only |
| Honour gitignore | `tree --gitignore` | Reads `.gitignore` from cwd upward |
| Show sizes | `tree -s` / `tree -h` | Bytes / human-readable |
| Recursive size | `tree --du -h` | Dir totals (slow on big trees) |
| Show hidden | `tree -a` | Includes dotfiles |
| Follow symlinks | `tree -l` | Cycles are detected |
| ASCII output | `tree --charset ascii` | For terminals without UTF-8 |
| JSON / XML / HTML | `tree -J` / `-X` / `-H .` | Machine-readable formats |
| Hide summary | `tree --noreport` | Drops trailing "N directories, M files" |

## Common patterns

**Top-level overview of a repo:**
```bash
tree -L 2 -I 'target|node_modules|.git|.nix-output'
```

**Just the directory skeleton:**
```bash
tree -d -L 3
```

**Respect repo's .gitignore (mirrors what git sees):**
```bash
tree --gitignore -I '.git'
```

**Find Rust sources only:**
```bash
tree -P '*.rs' -I 'target' --matchdirs --prune
```

**Disk usage per directory, human-readable, sorted:**
```bash
tree -du -h --sort=size -L 2
```

## Common pitfalls

- **`-I` takes globs, not regex**: use `-I 'target|node_modules'` (pipe-separated globs), not `-I '^target$'`. No anchoring, no character classes — fnmatch only.
- **`--du` walks the entire subtree**: on a workspace with `target/` (multi-GB) it can take minutes. Always combine with `-I 'target|node_modules'` or `-L <depth>` first.
- **`--gitignore` needs git context**: tree walks upward looking for `.gitignore` and `.git/`. Run from inside the repo, not from `/tmp`. Nested ignores apply only when the parent `.gitignore` is found.
- **`-P` filters files but keeps every directory**: by default `-P '*.rs'` shows empty dirs everywhere. Add `--prune` to hide empty branches and `--matchdirs` if your pattern should also match directory names.
- **`--noreport` hides the count**: handy in docs, but you lose the "X directories, Y files" sanity check — easy to miss a missing `-L` and dump 50k lines.
- **Symlink loops without `-l` cap**: `tree -l` follows symlinks but detects cycles; `tree` without `-l` skips them. A bare `find -L` would loop forever — tree won't, but the output explodes.
- **Charset on minimal containers**: forge images set UTF-8, but piping into a log file viewed on a non-UTF8 terminal renders garbage. Use `--charset ascii` when the consumer is unknown.

## See also

- `utils/fd.md` — fast file finder, better for "list matching paths"
- `utils/ripgrep.md` — content search; use alongside tree for "what's here, what's in it"

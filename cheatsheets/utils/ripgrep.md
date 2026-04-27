# ripgrep (rg)

@trace spec:agent-cheatsheets

**Version baseline**: ripgrep 14.x (Fedora 43).
**Use when**: searching code in the forge. Faster than grep, respects `.gitignore` by default, sane Unicode defaults.

## Provenance

- ripgrep user guide (BurntSushi/ripgrep): <https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md> — flags, file types, glob filtering
- ripgrep CHANGELOG and flag reference: <https://github.com/BurntSushi/ripgrep> — `--type-list`, `--json`, `--pcre2`, flag inventory
- Rust regex crate syntax docs: <https://docs.rs/regex/latest/regex/#syntax> — confirms the default regex engine (Rust `regex`, not PCRE)
  local: `cheatsheet-sources/docs.rs/regex/latest/regex`
- **Last updated:** 2026-04-25

Verified: `-t <type>` and `-g '<glob>'` confirmed in user guide; default regex engine is Rust `regex` (not PCRE — confirmed via regex crate reference in GUIDE.md); `-P` enables PCRE2; `-l` (files-with-matches), `--json` (structured output), `--no-ignore`, `--hidden` all documented in the ripgrep repository.

## Quick reference

| Flag | Effect |
|---|---|
| `-t <type>` | restrict to a file type (`rg -t rust foo`); list with `--type-list` |
| `-T <type>` | exclude a file type (`rg -T test foo`) |
| `-F` | treat pattern as a fixed string (no regex) |
| `-w` | match whole words only |
| `-i` / `-S` | case-insensitive / smart-case (lower → insensitive, mixed → sensitive) |
| `-A N` / `-B N` / `-C N` | N lines after / before / around each match |
| `-l` / `--files-with-matches` | print only filenames that contain a match |
| `--files` | list every file rg would search (no pattern needed) |
| `-g '<glob>'` | include/exclude by glob (`-g '!*.lock'`, `-g '*.toml'`) |
| `--multiline` (`-U`) | allow `.` and patterns to span newlines |
| `--json` | structured output for piping into other tools |
| `--no-ignore` | do not honor `.gitignore` / `.ignore` files |
| `--hidden` | descend into dotfiles/dotdirs |
| `-r '<repl>'` / `--replace` | print matches with capture groups substituted (no in-place edit) |
| `--passthru` | print every line, highlighting matches (pairs well with `-r`) |

## Common patterns

### Pattern 1 — narrow by language

```bash
rg -t rust 'fn main\(' crates/
rg -t toml -t md 'spec:agent-cheatsheets'
```

`-t` is faster and more precise than glob filtering; types are predefined (`rg --type-list`).

### Pattern 2 — multiline regex

```bash
rg -U 'struct\s+Forge\s*\{[^}]*pub\s+name'
```

`-U` (`--multiline`) lets the pattern span newlines. Add `--multiline-dotall` if you also want `.` to match `\n`.

### Pattern 3 — combine `--files` with a second `rg` pass

```bash
rg --files -t rust | rg -v '/tests/' | xargs rg 'tokio::spawn'
```

`--files` emits the candidate file list; pipe through another `rg` to filter paths, then search inside the survivors.

### Pattern 4 — list filenames only

```bash
rg -l '@trace spec:forge-launch'
```

`-l` is the right tool for "where is X mentioned"; pipe into `xargs $EDITOR` or `fzf`.

### Pattern 5 — preview a refactor with `--replace --passthru`

```bash
rg --passthru -r 'tillandsias_core' 'tillandsias-core' -t rust
```

Prints the entire file with substitutions highlighted. Non-destructive — combine with `sd` or `sed -i` once you trust the diff.

## Common pitfalls

- **Regex flavor is Rust `regex`, not PCRE** — no lookbehind/lookahead by default, no backreferences. Pass `-P` (`--pcre2`) when you need them; PCRE2 is slower and not always available in stripped builds.
- **`.gitignore` is honored by default** — searches inside `target/`, `node_modules/`, `.nix-output/` silently return nothing. Use `--no-ignore` (or `-uu` / `-uuu` to also include hidden + binary) when grepping build output.
- **Pattern starts with `-`** — rg treats it as a flag and errors. Separate with `--`: `rg -- '-Wno-foo' src/`.
- **`-U` / `--multiline` disables the auto single-line optimization** — searches get noticeably slower on large trees. Scope with `-t` or a path argument.
- **Smart-case surprises** — `rg Foo` is case-sensitive (mixed case), `rg foo` is case-insensitive. Force one mode with `-s` (sensitive) or `-i` (insensitive) when scripting.
- **`--json` streams one event per line, not one match** — events include `begin`, `match`, `context`, `end`, `summary`. Filter on `.type == "match"` before extracting `.data.lines.text`.
- **Globs need quoting** — unquoted `-g *.rs` is expanded by the shell first. Always single-quote: `-g '*.rs'`.

## See also

- `utils/fd.md` — `find` replacement, complementary file discovery
- `utils/fzf.md` — interactive narrowing of `rg -l` / `rg --files` output

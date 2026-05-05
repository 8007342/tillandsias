# fzf (Fuzzy Finder)

@trace spec:agent-source-of-truth

**Version baseline**: fzf 0.48.0 (Fedora 43)  
**Use when**: Interactively selecting files, commands, or search results from piped input

## Provenance

- https://github.com/junegunn/fzf — fzf official repository (canonical reference)
- https://github.com/junegunn/fzf/wiki — Advanced usage and keybindings
- **Last updated:** 2026-04-27

## Quick reference

| Flag / Binding | Effect |
|---|---|
| `--multi` / `-m` | Multi-select with Tab; emits one line per pick |
| `--preview '<cmd> {}'` | Right-pane preview; `{}` = current line |
| `--preview-window=right:60%:wrap` | Size, position, wrap of preview pane |
| `--bind 'ctrl-y:execute(echo {} \| xclip)'` | Custom key actions |
| `--height=40% --reverse` | Inline mode, prompt on top |
| `--ansi` | Honor ANSI color codes in input |
| `--query=<str>` | Pre-fill the search query |
| `--exit-0 --select-1` | Auto-exit if 0 / auto-pick if 1 match |
| `--header='<text>'` | Sticky header above results |
| `Esc` / `Ctrl-C` | Cancel (exit code 130) |

## Common patterns

**Pick file with preview:**
```bash
fd --type f | fzf --preview 'bat --color=always {}'
```

**Fuzzy git log with diff:**
```bash
git log --oneline --color=always |
  fzf --ansi --preview 'git show --color=always {1}'
```

**Multi-select for batch delete:**
```bash
fd --type f | fzf --multi | xargs -r rm -i
```

**Capture selection in script:**
```bash
sel=$(printf '%s\n' "${branches[@]}" | fzf --height=40% --reverse) || exit 130
git switch "$sel"
```

**Custom key binding for actions:**
```bash
fzf --bind 'ctrl-o:execute-silent(xdg-open {})+abort' \
    --bind 'ctrl-e:execute($EDITOR {})'
```

## Common pitfalls

- **Shell integration not auto-loaded**: `Ctrl-T`/`Ctrl-R`/`Alt-C` need `/usr/share/fzf/shell/key-bindings.bash` sourced (or zsh equivalent).
- **`--preview` spawns per keystroke**: Heavy commands lag on every move. Cache, truncate, or gate behind `--preview-window=hidden`.
- **Large lists render slowly**: Pre-filter with `fd`/`rg`; consider `--algo=v1` for very large inputs.
- **ANSI colors appear as garbage**: Input with color codes needs `--ansi`. Common with `git log --color=always`.
- **Exit code 130 on Esc**: Scripts ignoring `$?` treat cancellation as success-with-empty. Always `|| exit 130`.
- **Field expressions unquoted**: `--preview "cat {1}"` breaks on spaces. Use `{}` for whole line or quote: `--preview 'cat "{1}"'`.
- **fzf needs TTY on stderr**: Redirecting stderr (`2>/dev/null`) hangs fzf. Keep stderr attached.

## See also

- `utils/rg-fd-search.md` — Fast file search to pipe into fzf
- `languages/bash.md` — Command substitution, process substitution with fzf

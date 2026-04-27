---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://github.com/junegunn/fzf
  - https://junegunn.github.io/fzf/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# fzf

@trace spec:agent-cheatsheets

**Version baseline**: fzf 0.50+ (Fedora 43).
**Use when**: interactive fuzzy selection — files, history, branches, any newline-delimited list.

## Provenance

- fzf GitHub repository (junegunn/fzf) — README and flag reference: <https://github.com/junegunn/fzf> — authoritative source for all flags and shell integration
- fzf official documentation site: <https://junegunn.github.io/fzf/> — usage, key bindings, preview window
- **Last updated:** 2026-04-25

Verified: `--multi`/`-m` enables Tab multi-select (confirmed in README); `{}` is replaced with the focused line in `--preview`; `--preview 'cat {}'` pattern confirmed. Exit code 130 on Esc/Ctrl-C and `--exit-0`/`--select-1` are documented in the man page (`fzf --man`); not replicated in the README.

## Quick reference

| Flag / Binding | Effect |
|---|---|
| `--multi` / `-m` | Allow multi-select with Tab; emits one line per pick |
| `--preview '<cmd> {}'` | Right-pane preview; `{}` = current line |
| `--preview-window=right:60%:wrap` | Size, position, wrap of preview pane |
| `--bind 'ctrl-y:execute(echo {} \| xclip)'` | Custom key actions |
| `--height=40% --reverse` | Inline (non-fullscreen) mode, prompt on top |
| `--ansi` | Honor ANSI color codes in input |
| `--query=<str>` | Pre-fill the search query |
| `--exit-0 --select-1` | Auto-exit if 0 / auto-pick if 1 match |
| `--print-query` | Echo the query as the first output line |
| `--header='<text>'` | Sticky header above results |
| `Ctrl-T` (shell integration) | Insert selected file path at cursor |
| `Ctrl-R` (shell integration) | Fuzzy-search shell history |
| `Alt-C` (shell integration) | cd into selected subdirectory |
| `Ctrl-/` | Toggle preview window |
| `Esc` / `Ctrl-C` | Cancel — exit code 130 |

## Common patterns

**Pipe a fast finder into fzf with preview:**
```bash
fd --type f | fzf --preview 'bat --color=always {}'
```
`fd` enumerates, `bat` renders the highlighted preview. Swap `bat` for `cat` if missing.

**Fuzzy git log with diff preview:**
```bash
git log --oneline --color=always |
  fzf --ansi --preview 'git show --color=always {1}' \
      --bind 'enter:execute(git show {1} | less -R)'
```
`{1}` extracts the first whitespace-separated field (the SHA).

**Multi-select feeding another command:**
```bash
fd --type f | fzf --multi | xargs -r rm -i
```
Tab-mark several files, Enter, then `xargs` removes them interactively.

**Capture selection inside a script:**
```bash
sel=$(printf '%s\n' "${branches[@]}" | fzf --height=40% --reverse) || exit 130
git switch "$sel"
```
`|| exit 130` propagates the cancel exit code so callers know the user aborted.

**Custom key binding for inline actions:**
```bash
fzf --bind 'ctrl-o:execute-silent(xdg-open {})+abort' \
    --bind 'ctrl-e:execute($EDITOR {})'
```
`execute-silent` skips the screen redraw; `+abort` chains an exit after the action.

## Common pitfalls

- **Shell integration not auto-loaded in forge** — `Ctrl-T`/`Ctrl-R`/`Alt-C` only work after sourcing `/usr/share/fzf/shell/key-bindings.bash` (or the zsh equivalent). Forge bashrc may not include it; add explicitly or use raw `fzf` invocations in scripts.
- **`--preview` spawns a subshell per move** — heavy preview commands (e.g. `git log -p {}`) lag on every keystroke. Cache, `head`-truncate, or gate behind `--preview-window=hidden` + `Ctrl-/` to toggle.
- **Large lists render slowly** — feeding millions of lines blocks the UI. Pre-filter with `fd`/`rg` or use `--tac` only when needed; consider `--algo=v1` for very large inputs.
- **ANSI colors appear as escape garbage** — input with color codes needs `--ansi`, otherwise `^[[31m` shows literally. Common when piping `git log --color=always` or `rg --color=always`.
- **Exit code 130 on Esc/Ctrl-C** — scripts that don't check `$?` will treat cancellation as success-with-empty-output and proceed to delete/overwrite nothing-or-everything. Always `|| exit 130` (or check explicitly) after `fzf` in pipelines.
- **`{}` is shell-quoted, but field expressions are not** — `--preview 'cat {}'` is safe; `--preview "cat {1}"` (no quotes around `{1}`) breaks on filenames with spaces. Use `{}` for whole line, `{1..}` for fields-from-N, and quote when the source can produce spaces.
- **Tied terminals: fzf needs a TTY on stderr** — running fzf with stderr redirected (`2>/dev/null`) hangs or errors. Keep stderr attached to the terminal.

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
  - `https://github.com/junegunn/fzf`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/junegunn/fzf`
- **License:** see-license-allowlist
- **License URL:** https://github.com/junegunn/fzf

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/junegunn/fzf"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://github.com/junegunn/fzf" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/fzf.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/fd.md` — fast file enumerator, the canonical fzf feeder
- `utils/ripgrep.md` — content search; pair with `fzf --ansi` for live grep
- `utils/git.md` — `git log`/`git branch` outputs are common fzf inputs

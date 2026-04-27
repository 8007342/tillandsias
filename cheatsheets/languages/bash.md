---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://www.gnu.org/software/bash/manual/bash.html
  - https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
  - https://www.shellcheck.net/wiki/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Bash

@trace spec:agent-cheatsheets

## Provenance

- GNU Bash Reference Manual (Edition 5.3): <https://www.gnu.org/software/bash/manual/bash.html> — covers all parameter expansion forms (§3.5.3), set builtin flags -e/-u/-o pipefail (§4.3.1), IFS, trap, arrays (§6.7), here-docs, [[ ]] / (( )), process substitution (§3.5.6)
- POSIX Shell Command Language: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html> — POSIX baseline for portable shebang and [ ] test semantics
- ShellCheck wiki (common pitfalls): <https://www.shellcheck.net/wiki/> — SC2086, SC2091, and other lints referenced in pitfalls section
- **Last updated:** 2026-04-25

**Version baseline**: Bash 5.x (Fedora 43 default; zsh and fish also available in the forge)
**Use when**: writing shell scripts in the forge — entrypoints, build scripts, glue between tools.

## Quick reference

| Task | Syntax |
|------|--------|
| Strict mode | `set -euo pipefail; IFS=$'\n\t'` |
| Portable shebang | `#!/usr/bin/env bash` |
| Default value | `${var:-default}` (use default if unset/empty) |
| Assign default | `${var:=default}` (also sets `var`) |
| Error if unset | `${var:?message}` |
| Substring | `${var:offset:length}` |
| Strip prefix | `${var#prefix}` (shortest), `${var##prefix}` (longest) |
| Strip suffix | `${var%suffix}` (shortest), `${var%%suffix}` (longest) |
| Replace | `${var/old/new}` (first), `${var//old/new}` (all) |
| Length | `${#var}` |
| Uppercase / lowercase | `${var^^}` / `${var,,}` |
| Test (modern) | `[[ "$a" == "$b" ]]`, `[[ "$f" -nt "$g" ]]` |
| Numeric compare | `(( a > b ))` or `[[ a -gt b ]]` |
| Command substitution | `$(cmd)` (never backticks) |
| Arithmetic | `$(( 2 + 3 ))` |
| Array | `arr=(a b c); "${arr[@]}"` (each elem quoted) |
| Assoc array | `declare -A m; m[key]=val; "${m[key]}"` |
| Here-doc | `<<EOF` (expands), `<<'EOF'` (literal) |
| Here-string | `cmd <<< "$input"` |
| Redirect stderr | `cmd 2>&1` (merge), `cmd 2>/dev/null` (drop) |
| Process substitution | `diff <(cmd1) <(cmd2)` |

## Common patterns

### Pattern 1 — strict mode + safe IFS

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

`-e` exits on error, `-u` errors on unset vars, `-o pipefail` propagates pipe failures. `IFS` to newline+tab kills word-splitting on spaces in filenames.

### Pattern 2 — arrays (preserve spaces, no eval)

```bash
files=("with space.txt" "another.txt")
for f in "${files[@]}"; do
    [[ -f "$f" ]] && wc -l "$f"
done
```

`"${arr[@]}"` expands each element as a separate quoted word. `"${arr[*]}"` joins on `IFS[0]` — almost never what you want.

### Pattern 3 — here-doc, literal vs expanding

```bash
cat <<EOF > config.toml      # expands $VAR and $(cmd)
host = "$HOSTNAME"
EOF

cat <<'EOF' > script.sh       # quoted EOF -> no expansion
echo "$LITERAL_DOLLAR"
EOF
```

Quote the delimiter (`'EOF'`) when emitting code that contains `$` or backticks.

### Pattern 4 — signal traps for cleanup

```bash
tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM
# ... use $tmpdir ...
```

`trap ... EXIT` always runs (success, failure, signal). Add `INT TERM` so Ctrl-C still cleans up before the shell tears down.

### Pattern 5 — quoted command substitution + null-safe checks

```bash
sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
if [[ -z "${sha// }" ]]; then
    echo "no git sha" >&2
    exit 1
fi
```

Quote `"$(...)"` to preserve newlines and avoid word-splitting. Use `2>/dev/null || echo fallback` to short-circuit `set -e` for expected failures.

## Common pitfalls

- **Word splitting on unquoted vars** — `cp $src $dst` breaks on filenames with spaces. Always quote: `cp "$src" "$dst"`. ShellCheck SC2086.
- **Glob expansion in unquoted vars** — `echo $FOO` where `FOO="*.txt"` expands the glob. `echo "$FOO"` prints literally.
- **`cd` failure under `set -e`** — `cd /nonexistent && rm -rf .` is fine, but `cd /nonexistent; rm -rf .` deletes the wrong directory. Use `cd dir || exit` or rely on `set -e` only when `cd` is a standalone statement.
- **`while read` in a pipeline runs in a subshell** — `count=0; ls | while read f; do ((count++)); done; echo "$count"` prints `0`. Use process substitution instead: `while read f; do ((count++)); done < <(ls)`.
- **`[ ]` vs `[[ ]]`** — `[ ]` (POSIX `test`) requires quoting and word-splits unquoted vars; `[[ ]]` is a bash builtin that doesn't word-split and supports `=~` regex, `&&`, `||`. Always prefer `[[ ]]` in bash scripts.
- **Portable shebang matters** — `#!/bin/bash` breaks on macOS where bash 3.2 is at `/bin/bash` and bash 5+ is at `/opt/homebrew/bin/bash`. Use `#!/usr/bin/env bash` so PATH resolves it.
- **`set -e` does NOT propagate into functions called in a condition** — `if myfunc; then ...` ignores `set -e` inside `myfunc`. Use explicit `|| return 1` inside the function, or check `$?` after the call.
- **`$?` after a pipeline is the LAST command's exit** — without `set -o pipefail`, `false | true` exits 0. Always set `pipefail` in strict mode.
- **`IFS` not reset after temporary change** — leaks into the rest of the script. Save and restore: `OLD_IFS=$IFS; IFS=,; ...; IFS=$OLD_IFS`. Or scope in a subshell `( IFS=,; ... )`.
- **`read` strips leading/trailing whitespace and interprets backslashes** — use `IFS= read -r line` to read lines verbatim. The `-r` flag is almost always what you want.
- **Arithmetic with leading zeros** — `(( 010 + 1 ))` is 9 (octal!). Force base 10 with `10#010`.
- **`echo` interprets escapes inconsistently** — `echo -e` works in bash but not POSIX `sh`. Use `printf '%s\n' "$str"` for portable, predictable output.
- **`local` masks the exit status of its RHS** — `local x=$(failing_cmd)` always succeeds. Split: `local x; x=$(failing_cmd)`.

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
  - `https://www.gnu.org/software/bash/manual/bash.html`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.gnu.org/software/bash/manual/bash.html`
- **License:** see-license-allowlist
- **License URL:** https://www.gnu.org/software/bash/manual/bash.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.gnu.org/software/bash/manual/bash.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://www.gnu.org/software/bash/manual/bash.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/languages/bash.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/shellcheck-shfmt.md` — lint + format (catches most pitfalls above automatically)
- `runtime/forge-container.md` — entrypoints + container lifecycle
- `languages/python.md` — when bash gets too gnarly, switch to Python

# Bash

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

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

## See also

- `utils/shellcheck-shfmt.md` — lint + format (catches most pitfalls above automatically)
- `runtime/forge-container.md` — entrypoints + container lifecycle
- `languages/python.md` — when bash gets too gnarly, switch to Python

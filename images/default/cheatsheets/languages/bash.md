---
tags: [bash, shell, posix, scripting, msys2, git-bash, windows, cross-platform]
languages: [bash]
since: 2026-04-25
last_verified: 2026-04-28
sources:
  - https://www.gnu.org/software/bash/manual/bash.html
  - https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
  - https://www.shellcheck.net/wiki/
  - https://www.msys2.org/docs/filesystem-paths/
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
authority: vendor
status: active

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Bash

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime

## Provenance

- GNU Bash Reference Manual (Edition 5.3): <https://www.gnu.org/software/bash/manual/bash.html> — covers all parameter expansion forms (§3.5.3), set builtin flags -e/-u/-o pipefail (§4.3.1), IFS, trap, arrays (§6.7), here-docs, [[ ]] / (( )), process substitution (§3.5.6)
- POSIX Shell Command Language: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html> — POSIX baseline for portable shebang and [ ] test semantics
- ShellCheck wiki (common pitfalls): <https://www.shellcheck.net/wiki/> — SC2086, SC2091, and other lints referenced in pitfalls section
- MSYS2 — Filesystem Paths: <https://www.msys2.org/docs/filesystem-paths/> — authoritative reference for `MSYS_NO_PATHCONV`, automatic POSIX↔Win32 path translation rules, and `cygpath` semantics used by Git Bash
- Microsoft Learn — Basic commands for WSL: <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — `wsl.exe` invocation surface relevant when bash on Windows shells out to WSL
- **Last updated:** 2026-04-28

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

## Bash on Windows (Git Bash / MSYS2)

@trace spec:cross-platform, spec:windows-wsl-runtime
@cheatsheet runtime/wsl-on-windows.md, runtime/windows-native-dev-build.md

Tillandsias' `build-local.sh` and `scripts/build-sidecar.sh` execute on the Windows host under **Git Bash**, which is a stripped MSYS2 environment. Git Bash is `bash` (5.x) plus a thin POSIX emulation layer (`msys-2.0.dll`) that auto-translates Unix paths into Win32 paths whenever a `.exe` is invoked. Almost every cross-platform footgun on Windows traces back to that translator.

### Detection

```bash
case "$OSTYPE" in
    msys*|cygwin*) echo "Git Bash / MSYS2 / Cygwin" ;;
    linux-gnu*)   echo "real Linux (or WSL)"        ;;
    darwin*)       echo "macOS"                      ;;
esac

# Belt-and-braces — also handles users who export OSTYPE manually:
if [[ -n "${MSYSTEM:-}" ]]; then
    echo "MSYS2 ($MSYSTEM)"   # MSYSTEM is one of MSYS, MINGW64, UCRT64, CLANG64...
fi

# Inside WSL, /proc/sys/kernel/osrelease contains "microsoft" or "WSL":
[[ -r /proc/sys/kernel/osrelease ]] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease && echo "WSL"
```

### Path translation — the MSYS2 mangling rules

When Git Bash invokes a Windows `.exe`, every argument that **looks like** a POSIX path is rewritten to a Win32 path before exec. The full rule set is documented at <https://www.msys2.org/docs/filesystem-paths/>; the short version:

| Input argument        | Rewritten to (passed to .exe) | Notes |
|-----------------------|-------------------------------|-------|
| `/c/Users/bullo`     | `C:\Users\bullo`              | drive-letter root → backslash form |
| `/usr/local/bin`     | `C:\msys64\usr\local\bin`      | MSYS prefix root |
| `/bin/sh`             | `C:\msys64\usr\bin\sh.exe`     | MSYS-rooted, even when *intended literally* |
| `--foo=/c/x`          | `--foo=C:\x`                   | only the path part |
| `/c/x;/c/y`           | `C:\x;C:\y`                    | semicolon-separated lists |
| `//SERVER/share`      | left alone                     | UNC paths preserved |
| `//flag` (two slashes)| `/flag`                        | escape — strips one slash, no rewrite |

The translator is heuristic. It mangles `wsl.exe -- /bin/sh -c 'echo hi'` into `wsl.exe -- C:\msys64\usr\bin\sh.exe -c 'echo hi'` — wrong, because `/bin/sh` was meant to be evaluated **inside** WSL, not on the host.

### `MSYS_NO_PATHCONV=1` — disable translation per-call

```bash
# Wrong: Git Bash rewrites /bin/sh before wsl.exe ever sees it.
wsl.exe -- /bin/sh -c 'uname -a'

# Right: disable translation just for this call.
MSYS_NO_PATHCONV=1 wsl.exe -- /bin/sh -c 'uname -a'

# Equivalent escape — leading // is the per-arg opt-out:
wsl.exe -- //bin/sh -c 'uname -a'
```

Use `MSYS_NO_PATHCONV=1` whenever:
- the args are interpreted on the **other side** of an exec barrier (`wsl.exe`, `ssh.exe`, container CLIs)
- the args are URL-shaped (`/api/v1/...`) — MSYS will happily mangle them
- the tool already speaks both syntaxes (e.g. `git.exe` on Windows accepts `/c/x` directly)

`MSYS2_ARG_CONV_EXCL='*'` is the broader hammer (excludes specific arg patterns); `MSYS_NO_PATHCONV=1` is the right default for one-off escapes.

### `cygpath` — explicit conversion

```bash
cygpath -w /c/Users/bullo        # C:\Users\bullo                — Windows backslash
cygpath -m /c/Users/bullo        # C:/Users/bullo                — Windows forward-slash (preferred for Rust/Cargo)
cygpath -u 'C:\Users\bullo'      # /c/Users/bullo                — back to Unix form
cygpath -u 'C:\Users\bullo' -a   # /c/Users/bullo                — absolute (resolves .. and symlinks)
cygpath -w "$(pwd)"               # current dir as Windows path
```

Use `-m` (forward-slash Windows) when feeding paths to **Rust / Cargo / Tauri** — backslashes inside `Cargo.toml` or env vars are interpreted as escape sequences and silently corrupt the value. Use `-w` only for tools that explicitly want the native form (cmd.exe, PowerShell scripts).

```bash
# In build-local.sh — pass the workspace to a .exe that needs Windows form:
WORKSPACE_WIN=$(cygpath -w "$TILLANDSIAS_WORKSPACE")
some-tool.exe --workspace="$WORKSPACE_WIN"

# Pass to a Linux tool inside WSL — keep Unix form, but translate via /mnt/c:
WORKSPACE_WSL="/mnt/${TILLANDSIAS_WORKSPACE,,}"   # crude — see wslpath inside WSL
WORKSPACE_WSL=${WORKSPACE_WSL/c\:/c}              # strip colon
```

### BOMs and UTF-16 LE — `wsl.exe` output mangling

`wsl.exe` emits **UTF-16 LE with a BOM** by default. Piping its stdout into `awk`, `grep`, or even `wc -l` produces nonsense unless you strip the BOM and the embedded NULs:

```bash
# Wrong — output looks empty or full of \0 bytes:
wsl.exe --list --quiet | grep -v Default

# Right — strip NULs and CRs, then process:
wsl.exe --list --quiet | tr -d '\0\r' | grep -v '^Default'

# Even safer — set WSL_UTF8 globally (since Windows 10 build 19041, all WSL versions):
export WSL_UTF8=1
wsl.exe --list --quiet                         # now plain UTF-8, no BOM
```

`WSL_UTF8=1` is documented at <https://learn.microsoft.com/en-us/windows/wsl/basic-commands>. Tillandsias' `build-local.sh` exports it at the top of every script that shells out to `wsl.exe`. For the rare case it's not honoured (older WSL 1 builds), keep the `tr -d '\0\r'` filter as a belt-and-braces defence.

### Line endings — CRLF vs LF

Windows tools default to CRLF. POSIX tools choke on CR (`bash: \r: command not found`, `^M` in heredocs). Git is the gatekeeper:

```bash
# Per-file rule — committed as LF, never converted on checkout:
echo '*.sh   text eol=lf'   >> .gitattributes
echo '*.bash text eol=lf'   >> .gitattributes
echo 'Dockerfile text eol=lf' >> .gitattributes

# Globally — refuse to ever rewrite line endings on this repo:
git config --local core.autocrlf false

# Detect CRLF in files already in the index:
git ls-files --eol | grep 'w/crlf'

# Strip CR from a file in place (POSIX-safe):
sed -i 's/\r$//' offending.sh

# Same, with tr (works even on macOS BSD sed):
tr -d '\r' < offending.sh > offending.sh.lf && mv offending.sh.lf offending.sh
```

`.sh` files in this repo MUST be LF. The `.gitattributes` rule above is the only reliable enforcement — `core.autocrlf=input` still bites on clones from `windows-next`.

### Round-trip example — host bash → wsl.exe → wsl bash

```bash
#!/usr/bin/env bash
# Run a build inside WSL from Git Bash, with a Windows path argument.
set -euo pipefail
export WSL_UTF8=1                                 # plain UTF-8 from wsl.exe

# Translate the Windows-side workspace into a path WSL can see:
WIN_PATH="$(pwd)"                                  # /c/Users/bullo/src/foo
WSL_PATH="$(MSYS_NO_PATHCONV=1 wsl.exe wslpath -a -u "$(cygpath -w "$WIN_PATH")" \
            | tr -d '\0\r')"                       # -> /mnt/c/Users/bullo/src/foo

# Run a build with the Linux path; -- separates wsl.exe flags from the inner cmd:
MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias-forge --cd "$WSL_PATH" -- \
    /bin/bash -c 'set -euo pipefail; cargo build --release'
```

`MSYS_NO_PATHCONV=1` covers both calls: the first because `cygpath -w` produces a literal `C:\...` that should pass through unrewritten; the second because `/bin/bash` is meant for the WSL side.

### Limitations vs real Linux bash

- **No real `fork(2)`.** MSYS2 emulates fork via `CreateProcess` + memory copy. Pipelines and recursive scripts (`make -j`, `xargs -P`) are an order of magnitude slower than on Linux.
- **Slow startup.** `bash --version` on Git Bash is ~150 ms (loading `msys-2.0.dll`); PowerShell 7 cold-start is comparable but warm-start is faster. For one-shot scripts called from a Windows IDE, prefer PowerShell.
- **`realpath -e` may be missing on older Git Bash.** Test with `command -v realpath`. Fallback: `python -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$path"` or `cygpath -m -a "$path"`.
- **`stat -c` formats differ.** `stat -c %s file` works on MSYS2 but not BSD/macOS. Use `wc -c < file` for portable size.
- **Job control is partial.** `Ctrl-Z` / `bg` / `fg` work, but signals delivered from the Windows side (taskkill) do not always trigger `trap`.
- **Symlinks need elevated privilege or developer mode.** `ln -s` may produce a real symlink, a junction, or a copy depending on Windows mode and `MSYS=winsymlinks:nativestrict` env var.
- **Process tree visibility is asymmetric.** `ps` only sees MSYS2 processes; Windows processes (including the `.exe` you just spawned) appear via `tasklist.exe` instead.

When the script touches more than two of those, it's usually right to rewrite it as PowerShell (see `build-local.ps1` next to `build-local.sh`).

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

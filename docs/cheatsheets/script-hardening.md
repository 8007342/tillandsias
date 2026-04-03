# Script Hardening

## Overview

Tillandsias relies on bash scripts in two contexts: host-side build and install scripts (`build.sh`, `build-osx.sh`, `scripts/*.sh`) and container-side entrypoints (`images/default/*.sh`). A defensive coding error in either context can cause silent data corruption, command injection, or difficult-to-diagnose failures. This cheatsheet documents the hardening patterns required in all project scripts.

@trace spec:dev-build, spec:forge-launch

## The Reported Bug

A user reported that error text was being executed as commands. The root cause: an unquoted variable containing an error message was word-split by the shell and each word was interpreted as a command. For example:

```bash
# DANGEROUS: if $result contains "Error: file not found", the shell tries
# to execute "Error:" as a command, then "file", then "not", then "found"
output=$result        # unquoted assignment is fine
echo $result          # WRONG: word splitting + globbing
echo "$result"        # CORRECT: preserves the string as-is
```

This class of bug is entirely preventable with the patterns below.

## Strict Mode: set -euo pipefail

Every script in the project MUST begin with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

| Flag | Long form | What it does | Without it |
|------|-----------|-------------|------------|
| `-e` | `errexit` | Exit immediately when a command fails (nonzero exit) | Failures are silently ignored; the script continues in a corrupt state |
| `-u` | `nounset` | Treat unset variables as an error | Typo in a variable name silently expands to empty string |
| `-o pipefail` | n/a | A pipeline fails if ANY command in it fails, not just the last | `curl ... \| grep ...` succeeds even if `curl` fails |

### Caveats with set -e

`set -e` does NOT trigger on failures inside:
- `if` / `while` / `until` conditions: `if command_that_fails; then ...` is intentional
- Commands before `&&` or `||`: `cmd1 || handle_error` is a pattern, not a bug
- Command substitutions in some contexts (bash < 4.4)
- Functions called from a conditional context

When you need a command to be allowed to fail, be explicit:

```bash
# Explicit "allowed to fail" pattern
some_command || true

# Or capture the exit code
if ! some_command; then
    echo "some_command failed, handling gracefully"
fi
```

Source: `build.sh`, `lib-common.sh` (both use `set -euo pipefail`)

## Quoting All Variable Expansions

The single most important hardening rule: **always double-quote variable expansions**.

| Expression | Safe? | Why |
|-----------|-------|-----|
| `"$var"` | Yes | Preserves whitespace, prevents globbing |
| `$var` | No | Word-split on whitespace, glob patterns expanded |
| `"${var:-default}"` | Yes | Safe default with quoting |
| `${var:-default}` | No | Same word-split/glob risk |
| `"$@"` | Yes | Each positional parameter preserved as a separate word |
| `$@` | No | All parameters re-split |
| `"$(command)"` | Yes | Command output preserved |
| `$(command)` | No | Output re-split and globbed |

### Where quoting matters most

```bash
# File paths (spaces, special characters in names)
cp "$source_file" "$dest_dir/"

# Error messages (the reported bug)
msg="Error: file not found in $dir"
echo "$msg"                    # CORRECT
echo $msg                      # BUG: "Error:" executed as command in some contexts

# Loop variables
for f in "$HOME/src"/*/; do
    [ -d "$f" ] && process "$f"
done

# Array expansion
files=("file one.txt" "file two.txt")
rm "${files[@]}"               # CORRECT: each element is one argument
rm ${files[@]}                 # BUG: "file" and "one.txt" become separate args
```

### The one place quoting is not needed

Inside `[[ ... ]]` (bash's extended test), the right-hand side of `=` and `!=` does not word-split. But quoting there is still harmless and recommended for consistency.

## Using -- to Separate Options from Arguments

When passing user-controlled or variable data as arguments, use `--` to signal end-of-options:

```bash
# DANGEROUS: if $filename starts with "-", it's interpreted as a flag
rm $filename                   # could be "rm -rf /"
cat $filename                  # could be "cat --help"

# SAFE: -- tells the command that everything after it is an argument
rm -- "$filename"
cat -- "$filename"
grep -- "$pattern" "$file"

# Especially important with find, xargs, git
git checkout -- "$file"
find "$dir" -name "$pattern" -- 
```

This is relevant in Tillandsias because project names and file paths come from user input.

## Avoiding eval and Command Injection

`eval` reinterprets its arguments as shell code. It is almost never needed and is the most common source of injection vulnerabilities in shell scripts.

```bash
# NEVER do this
eval "$user_input"
eval "cmd --flag=$untrusted"

# If you think you need eval, you probably need one of these instead:
# Arrays for dynamic argument lists
args=("--flag1" "--flag2" "$dynamic_value")
command "${args[@]}"

# Associative arrays for dynamic variable names (bash 4+)
declare -A config
config["$key"]="$value"

# Indirect expansion (bash)
varname="MY_VAR"
echo "${!varname}"             # prints the value of $MY_VAR
```

### Command injection vectors to watch for

```bash
# DANGEROUS: interpolating into a command string
filename='"; rm -rf / #'
system("process $filename")    # injection

# DANGEROUS: unquoted backticks or $() in eval
eval "result=$(untrusted_command)"

# SAFE: pass data as arguments, never as code
command --file="$filename"
```

The project has zero `eval` statements. Keep it that way.

## ShellCheck

[ShellCheck](https://www.shellcheck.net/) is a static analysis tool for shell scripts. It catches quoting bugs, TOCTOU issues, common pitfalls, and style problems.

### Running ShellCheck

```bash
# Single file
shellcheck build.sh

# All project scripts
shellcheck build.sh build-osx.sh build-windows.sh scripts/*.sh images/default/*.sh

# Specific shell dialect
shellcheck --shell=bash script.sh

# Exclude specific warnings (document why in the script)
# shellcheck disable=SC2034  # variable appears unused (it's exported by source)
```

### Key ShellCheck codes relevant to this project

| Code | What it catches | Example |
|------|----------------|---------|
| SC2086 | Unquoted variable (word splitting) | `echo $var` -> `echo "$var"` |
| SC2046 | Unquoted command substitution | `rm $(find ...)` -> `rm "$(find ...)"` |
| SC2006 | Backtick command substitution | `` `cmd` `` -> `$(cmd)` |
| SC2155 | Declare and assign separately | `local var=$(cmd)` masks exit code |
| SC2164 | `cd` without `\|\| exit` | `cd "$dir"` -> `cd "$dir" \|\| exit 1` |
| SC2035 | Glob used as command | `*.txt` -> `./*.txt` |

### SC2155: the hidden exit-code trap

```bash
# WRONG: local always returns 0, masking the failure of "command"
local result="$(command)"

# CORRECT: declare and assign separately
local result
result="$(command)"
# Now set -e can catch a failure in "command"
```

This pattern appears in many projects. Always declare `local` variables on a separate line from their assignment when the value comes from a command substitution.

## Trap for Cleanup on Error

Use `trap` to ensure cleanup runs regardless of how the script exits.

```bash
# Pattern: cleanup function + trap
cleanup() {
    rm -f "$tmpfile"
    # Restore state, kill background processes, etc.
}
trap cleanup EXIT        # runs on ANY exit (success, failure, signal)
trap cleanup ERR         # runs only on error (with set -e)

# For multiple signals (container entrypoints)
trap 'exit 0' SIGTERM SIGINT   # graceful shutdown in containers
```

### Trap ordering

```bash
# Traps are per-signal. Setting a new trap replaces the old one.
trap 'echo first' EXIT
trap 'echo second' EXIT   # REPLACES the first trap

# To chain cleanup, call functions:
trap 'cleanup_temp; cleanup_mounts; cleanup_processes' EXIT
```

### Real example from the project

`lib-common.sh` uses `trap 'exit 0' SIGTERM SIGINT` so that container entrypoints shut down cleanly when podman sends termination signals, rather than printing error messages about interrupted commands.

Source: `images/default/lib-common.sh` line 16

## Input Validation Patterns

Never trust input from environment variables, command arguments, file contents, or user-provided paths.

```bash
# Validate expected values with a case statement (no regex needed)
case "$mode" in
    debug|release|test|check) ;;
    *) echo "error: unknown mode: $mode" >&2; exit 1 ;;
esac

# Validate that a variable is set and non-empty
: "${REQUIRED_VAR:?error: REQUIRED_VAR must be set}"

# Validate a path doesn't escape its prefix
realpath_target="$(realpath -- "$user_path")"
case "$realpath_target" in
    /allowed/prefix/*) ;;
    *) echo "error: path outside allowed directory" >&2; exit 1 ;;
esac

# Validate numeric input
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "error: port must be a number" >&2
    exit 1
fi

# Validate non-empty before use
if [ -z "${PROJECT_DIR:-}" ]; then
    echo "error: no project directory found" >&2
    exit 1
fi
```

### Default values for optional variables

```bash
# ${var:-default} — use default if unset or empty
MAINTENANCE="${TILLANDSIAS_MAINTENANCE:-0}"

# ${var:=default} — assign default if unset or empty (side effect: sets the var)
: "${CACHE_DIR:=$HOME/.cache/tillandsias}"
```

Source: `images/default/entrypoint.sh` (uses `${TILLANDSIAS_MAINTENANCE:-0}` pattern)

## Safe Temporary File Creation with mktemp

Never construct temporary filenames manually. Use `mktemp`, which creates files with unique names and restrictive permissions (0600) atomically.

```bash
# DANGEROUS: predictable name, race condition, symlink attack
tmpfile="/tmp/myapp_$$"
echo "data" > "$tmpfile"

# SAFE: unique name, 0600 permissions, atomic creation
tmpfile="$(mktemp /tmp/tillandsias.XXXXXXXXXX)"

# SAFE: temporary directory (0700 permissions)
tmpdir="$(mktemp -d /tmp/tillandsias.XXXXXXXXXX)"

# Always clean up
trap 'rm -rf "$tmpfile" "$tmpdir"' EXIT
```

### Why manual temp files are dangerous

1. **Predictable names**: `/tmp/myapp_$$` uses PID, which is guessable
2. **Symlink attacks**: attacker creates a symlink at the predicted path pointing to `/etc/passwd`; your script overwrites the target
3. **Race condition**: between checking if a file exists and creating it, another process can act

### Atomic file writes

When writing a file that other processes might read, write to a temp file first, then rename:

```bash
# Atomic write pattern (used in token_file::write in the Rust code)
tmpfile="$(mktemp "${target_file}.XXXXXXXXXX")"
echo "$content" > "$tmpfile"
mv -- "$tmpfile" "$target_file"
# mv is atomic on the same filesystem (POSIX guarantee)
```

Source: `docs/cheatsheets/secret-management.md` describes this atomic write pattern for token files

## Avoiding TOCTOU Races

Time-of-check to time-of-use (TOCTOU) bugs occur when there is a gap between checking a condition and acting on it, during which the condition can change.

```bash
# TOCTOU BUG: another process could create/delete the file between test and use
if [ ! -f "$file" ]; then
    echo "data" > "$file"     # might overwrite a file created by another process
fi

# SAFER: use noclobber (set -C) to make > fail if file exists
set -C
echo "data" > "$file" 2>/dev/null || echo "file already exists"

# SAFER: use mkdir as an atomic lock (mkdir is atomic on POSIX)
if mkdir "$lockdir" 2>/dev/null; then
    # we hold the lock
    trap 'rmdir "$lockdir"' EXIT
else
    echo "another instance is running"
    exit 1
fi

# SAFER: use mktemp + mv for atomic file creation (see above)

# TOCTOU BUG: checking permissions then reading
if [ -r "$file" ]; then
    cat "$file"               # permissions could change between test and read
fi

# SAFER: just try to read and handle the error
cat "$file" 2>/dev/null || { echo "cannot read $file" >&2; exit 1; }
```

### Rule of thumb

Instead of "check then act", prefer "act and handle failure". This eliminates the window between check and use.

## IFS Handling

`IFS` (Internal Field Separator) controls how bash splits unquoted strings. The default is space, tab, newline. Changing IFS affects all subsequent word splitting.

```bash
# Default IFS splits on whitespace
line="one two three"
for word in $line; do echo "$word"; done   # prints one, two, three

# Reading colon-separated data (like PATH)
IFS=':' read -ra path_parts <<< "$PATH"

# ALWAYS restore IFS or use a subshell
old_ifs="$IFS"
IFS=','
# ... do comma-separated work ...
IFS="$old_ifs"

# BETTER: use a subshell so IFS change doesn't leak
(
    IFS=','
    # ... comma work stays contained ...
)

# SAFEST: avoid relying on IFS entirely — use proper quoting
# instead of manipulating IFS for word splitting, use arrays:
readarray -t lines < "$file"
for line in "${lines[@]}"; do
    process "$line"
done
```

### IFS pitfall with read

```bash
# Without IFS, leading/trailing whitespace is stripped
read -r var <<< "  hello  "
echo "[$var]"                  # [hello]

# Preserve whitespace
IFS= read -r var <<< "  hello  "
echo "[$var]"                  # [  hello  ]
```

## Quick Reference Table

| Category | Do | Do not |
|----------|-----|--------|
| Script header | `set -euo pipefail` | Bare `#!/bin/bash` with no flags |
| Variables | `"$var"`, `"${var:-default}"` | `$var`, `${var:-default}` |
| Positional args | `"$@"` | `$@` or `$*` |
| Command subs | `"$(command)"` | `` `command` `` or unquoted `$(command)` |
| End of options | `rm -- "$file"` | `rm "$file"` when file may start with `-` |
| Dynamic args | `args=(...); cmd "${args[@]}"` | `eval "cmd $dynamic"` |
| Temp files | `mktemp /tmp/app.XXXXXXXXXX` | `/tmp/app_$$` or `/tmp/app_$RANDOM` |
| File writes | Write to temp + `mv` to target | Write directly to target |
| Check then act | Try the operation, handle failure | `if [ -f ]; then use` |
| Allowed failure | `cmd \|\| true` | Removing `set -e` |
| Local variables | `local x; x="$(cmd)"` | `local x="$(cmd)"` (masks exit code) |
| Cleanup | `trap cleanup EXIT` | No cleanup, or cleanup only in main path |
| Linting | `shellcheck` on all scripts | Manual review only |

## Sources

- [Writing Safe Shell Scripts -- MIT SIPB](https://sipb.mit.edu/doc/safe-shell/)
- [Bash Best Practices -- Bert Van Vreckem](https://bertvv.github.io/cheat-sheets/Bash.html)
- [Bash Scripting Quirks and Safety Tips -- Julia Evans](https://jvns.ca/blog/2017/03/26/bash-quirks/)
- [9 Tips for Writing Safer Shell Scripts -- Belief Driven Design](https://belief-driven-design.com/9-tips-safer-shell-scripts-5b8d6afd618/)
- [Safely Creating and Using Temporary Files -- netmeister.org](https://www.netmeister.org/blog/mktemp.html)
- [Avoid Race Conditions -- David Wheeler, Secure Programming HOWTO](https://dwheeler.com/secure-programs/Secure-Programs-HOWTO/avoid-race.html)
- [Avoid Insecure Temp Files: mktemp Fixes -- Secure Coding Practices](https://securecodingpractices.com/avoiding-insecure-temporary-file-creation-scripts-mktemp-usage/)
- [Race Conditions and Secure File Operations -- Apple Developer](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)
- [ShellCheck](https://www.shellcheck.net/)

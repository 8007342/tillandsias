## Context

All entrypoint scripts source `lib-common.sh`, which sets `set -euo pipefail` for strict error handling. This is good practice, but several functions have exit-code paths that interact badly with `set -e`:

- **Bash `set -e` rule**: A function's return code is the exit code of its last executed statement. If that's nonzero and the function is called outside of `if`/`&&`/`||` context, the script terminates.

- **Glob behavior**: When a glob pattern like `"$HOME/src"/*/` matches nothing, bash returns the literal string (unless `nullglob` is set). This means `[ -d "/home/forge/src/*/" ]` returns 1, which becomes the for-loop's exit code, which becomes the function's return code.

## Root Cause Analysis

**Bug 1** — `find_project_dir()`:
```bash
find_project_dir() {
    PROJECT_DIR=""
    for dir in "$HOME/src"/*/; do
        [ -d "$dir" ] && PROJECT_DIR="$dir" && break  # exits 1 when glob is literal
    done
    # no explicit return — function returns for-loop's exit code (1)
}
```
The for-loop is the last statement. Its exit code is the last body command's exit code. `[ -d "/home/forge/src/*/" ]` fails, the `&&` chain short-circuits with exit 1. The function returns 1. The caller (`find_project_dir` on its own line) triggers `set -e`.

**Bug 2** — `install_opencode()`:
```bash
if ! curl ...; then
    echo "ERROR: ..."
    return 1   # <-- fatal under set -e at call site
fi
tar xzf ...    # <-- also fatal under set -e if tarball is corrupt
chmod +x ...   # <-- also fatal if file doesn't exist
```
The explicit `return 1` and unguarded `tar`/`chmod` commands propagate failures to the caller.

## Goals / Non-Goals

**Goals:**
- Every entrypoint survives: empty `$HOME/src/`, network offline, corrupt downloads
- Failures print clear error messages and fall back to bash instead of crashing silently

**Non-Goals:**
- Removing `set -e` (it catches real bugs; we keep it)
- Changing the entrypoint dispatch mechanism

## Decisions

**Add `return 0` to `find_project_dir()`**: The simplest, most explicit fix. An alternative (`shopt -s nullglob`) would change bash behavior globally, with unpredictable side effects. `return 0` documents the intent clearly.

**Change `return 1` to `return 0` in `install_opencode()`**: The function's callers don't check its return code — they check `[ -x "$OC_BIN" ]` later. The return code is meaningless; making it 0 prevents `set -e` from interfering.

**Wrap `tar` in `if` guard**: `tar xzf` can fail on corrupt archives. Moving it into an `if` statement lets `set -e` ignore the failure while the script prints an error and continues.

**Add `|| true` to `chmod`**: If the extracted binary doesn't exist, `chmod` fails. This is a symptom, not the root cause — the error message from `tar` is sufficient.

## Risks / Trade-offs

- [Risk] `return 0` masks the install failure at the function level. Mitigation: the entrypoint's final `if [ -x "$OC_BIN" ]` check catches it and falls back to bash with a clear error message. The failure is not hidden, just non-fatal.

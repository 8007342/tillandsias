## Context

`open_terminal()` takes a single command string and passes it to the shell (via AppleScript on macOS, bash -c on Linux). The args are built as a `Vec<String>` by `build_podman_args()` then joined with spaces. Any arg containing whitespace (like `-e TILLANDSIAS_HOST_OS=macOS 26.4`) is split by the shell into multiple tokens.

## Goals / Non-Goals

**Goals:**
- All podman args containing whitespace are properly shell-quoted when building terminal commands
- No functional change to the podman execution (only affects the shell command string)

**Non-Goals:**
- Refactoring open_terminal() to take args as Vec (would be a larger change)
- Quoting for other special shell characters (not needed for current env var values)

## Decisions

**Single-quote wrapping**: Use `'arg with spaces'` style quoting. Single quotes prevent all shell interpretation, which is the safest approach. Internal single quotes are escaped with `'\''` (end quote, escaped quote, start quote).

**Fix at join site, not at build site**: The `build_podman_args()` function returns clean unquoted args suitable for `.args()` (direct exec). Quoting is only applied when joining into a shell command string. This keeps the args reusable.

## Risks / Trade-offs

- [Risk] Future env values with single quotes could still break. Mitigation: the `shell_quote` function handles embedded single quotes with standard `'\''` escaping.

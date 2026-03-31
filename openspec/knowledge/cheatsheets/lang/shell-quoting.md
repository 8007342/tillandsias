# Shell Quoting

## The Problem
When building shell command strings by joining args with spaces, values containing
whitespace get split into multiple tokens. Example: `-e TILLANDSIAS_HOST_OS=macOS 26.4`
becomes two args: `-e TILLANDSIAS_HOST_OS=macOS` and `26.4`.

## POSIX Quoting Rules
- **Single quotes** `'...'`: No interpretation at all. Safest for untrusted values.
  - To include a literal `'` inside: `'it'\''s'` (end quote, escaped quote, start quote)
- **Double quotes** `"..."`: Variables (`$VAR`) and backticks expanded. Less safe.
- **No quotes**: Word splitting + glob expansion. Never use for untrusted values.

## Rust shell_quote Pattern
```rust
fn shell_quote(arg: &str) -> String {
    if arg.contains(' ') || arg.contains('\t') {
        format!("'{}'", arg.replace('\'', "'\\''"))
    } else {
        arg.to_string()
    }
}
```

## When to Quote
- `Command::new().args(&vec)` — NO quoting needed (OS handles separation)
- `Command::new("bash").args(["-c", &cmd_string])` — MUST quote args with spaces
- AppleScript `do script "cmd"` — MUST quote (interpreted by shell)
- `.join(" ")` for display/debug — quote for readability

## Tillandsias Context
- `build_podman_args()` returns clean unquoted args (for `.args()`)
- `join_shell_args()` applies quoting when building terminal command strings
- `open_terminal()` passes command to shell via AppleScript (macOS) or bash -c (Linux)
- Values that commonly contain spaces: `TILLANDSIAS_HOST_OS` (e.g., "macOS 26.4", "Fedora Silverblue 43")

## Common Pitfalls
- `.join(" ")` on args with spaces = broken shell commands
- Quoting at the wrong layer (quote in `build_podman_args` breaks `.args()` usage)
- Missing quoting in debug output (misleading when user copies command)

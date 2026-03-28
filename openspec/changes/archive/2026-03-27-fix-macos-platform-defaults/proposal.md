# Fix macOS Platform Defaults

## Problem

Several source files use Linux-only system calls, paths, or CLI flags that
fail on macOS:

- `build_lock.rs` reads `/proc/{pid}/comm` (Linux-only procfs)
- `cleanup.rs` shells out to `du -sb` (`-b` flag doesn't exist on macOS)
- `cleanup.rs` hardcodes `~/.cache/tillandsias/...` and `~/.local/bin/...`
- `uninstall.sh` hardcodes `LIB_DIR` and `DATA_DIR` to Linux paths
- `gh-auth-login.sh` hardcodes `DATA_DIR` to `~/.local/share/tillandsias`
- `claude-api-key-prompt.sh` and `handlers.rs` use `$XDG_RUNTIME_DIR` with
  `/tmp` fallback — macOS should prefer `$TMPDIR`

## Solution

Apply platform detection consistently:

1. **build_lock.rs**: Add `#[cfg(target_os)]` split matching `singleton.rs`
2. **cleanup.rs**: Replace `du -sb` with `std::fs` recursive walk; use
   `tillandsias_core::config::cache_dir()` for paths; use platform-aware
   binary path
3. **uninstall.sh**: Add Darwin detection for `LIB_DIR` and `DATA_DIR`
4. **gh-auth-login.sh**: Add Darwin detection for `DATA_DIR`
5. **claude-api-key-prompt.sh**: Use `$TMPDIR` on macOS
6. **handlers.rs**: Use `std::env::temp_dir()` instead of hardcoded `/tmp`

## Scope

Bug fix only. No new features. No behavior change on Linux.

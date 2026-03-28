# fix-gh-auth-macos-path

Fix hardcoded `~/.cache/tillandsias` paths in shell scripts that break on macOS, where the Rust code uses `~/Library/Caches/tillandsias` via `dirs::cache_dir()`.

**Status**: in-progress

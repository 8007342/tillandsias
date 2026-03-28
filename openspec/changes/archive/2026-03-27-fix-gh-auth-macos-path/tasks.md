## 1. Fix shell scripts

- [x] 1.1 `gh-auth-login.sh` — Replace hardcoded CACHE_DIR with platform detection
- [x] 1.2 `gh-auth-login.sh` — Update help text comment paths to mention both platforms
- [x] 1.3 `build-osx.sh` — Use macOS-native cache path
- [x] 1.4 `scripts/uninstall.sh` — Add platform detection for CACHE_DIR

## 2. Migrate existing credentials

- [x] 2.1 Move credentials from `~/.cache/tillandsias/secrets/` to `~/Library/Caches/tillandsias/secrets/` on macOS

## 3. Verify

- [x] 3.1 Run `cargo test --workspace` — 96 passed, 1 ignored

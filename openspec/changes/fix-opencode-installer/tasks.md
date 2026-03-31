## 1. Rewrite OpenCode install/update

- [x] 1.1 Replace `install_opencode()` and `update_opencode()` with single `ensure_opencode()` using official `curl -fsSL https://opencode.ai/install | bash`
- [x] 1.2 Set `OPENCODE_INSTALL_DIR=$CACHE/opencode` so binary persists in cache
- [x] 1.3 OC_BIN path unchanged (`$CACHE/opencode/bin/opencode`) — official installer respects OPENCODE_INSTALL_DIR
- [x] 1.4 Daily throttle via `needs_update_check`/`record_update_check` preserved

## 2. Verify

- [x] 2.1 `./build-osx.sh --check` compiles clean
- [x] 2.2 `./build-osx.sh --test` — all tests pass
- [x] 2.3 Installed release build

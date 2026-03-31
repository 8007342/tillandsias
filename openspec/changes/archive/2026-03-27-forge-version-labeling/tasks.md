## 1. Pass TILLANDSIAS_FORGE_VERSION env var to containers

- [x] 1.1 Add `TILLANDSIAS_FORGE_VERSION` to `build_run_args()` in `handlers.rs`
- [x] 1.2 Add `TILLANDSIAS_FORGE_VERSION` to terminal format string in `handle_terminal()` (handlers.rs)
- [x] 1.3 Add `TILLANDSIAS_FORGE_VERSION` to root terminal format string in `handle_root_terminal()` (handlers.rs)
- [x] 1.4 Add `TILLANDSIAS_FORGE_VERSION` to `build_run_args()` in `runner.rs`

## 2. Display version in forge container

- [x] 2.1 Show forge version in entrypoint.sh banner
- [x] 2.2 Show forge version in forge-welcome.sh display

## 3. Display version in app logs

- [x] 3.1 Add `CARGO_PKG_VERSION` to startup log line in `main.rs`
- [x] 3.2 Log forge image tag when launching environment in `handlers.rs`
- [x] 3.3 Add version to CLI "Attaching to" message in `runner.rs`

## 4. Verification

- [x] 4.1 `cargo test --workspace` passes

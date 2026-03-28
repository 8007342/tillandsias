## 1. PodmanClient

- [x] 1.1 Add `start_machine()` method to `PodmanClient` in `client.rs`

## 2. Main startup logic

- [x] 2.1 Add auto-start logic in `main.rs` between machine detection and `podman_usable` computation

## 3. Testing

- [x] 3.1 `cargo test --workspace` passes (96 tests, 0 failures)
- [x] 3.2 Live test: debug build runs, log confirms normal startup (machine was already running, auto-start correctly skipped)

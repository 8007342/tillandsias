## 1. Build Lock Module

- [x] 1.1 Add build lock functions to `src-tauri/src/build_lock.rs`: `acquire()`, `wait_for_build()`, `release()`, `is_running()`
- [x] 1.2 Lock file at `$XDG_RUNTIME_DIR/tillandsias/build-<image>.lock` with PID, stale detection

## 2. Init Command

- [x] 2.1 Add `CliMode::Init` to `cli.rs` with parsing for `tillandsias init`
- [x] 2.2 Create `src-tauri/src/init.rs` — acquire build lock, run embedded `build-image.sh` for forge, release lock, report status
- [x] 2.3 Add `mod init;` and dispatch in `main.rs`
- [x] 2.4 Handle "already built" case — check `podman image exists`, skip if present
- [x] 2.5 Handle "build in progress" case — detect lock, wait with progress dots, verify image after

## 3. Tray Integration

- [x] 3.1 In `handlers.rs` `run_build_image_script()`, acquire build lock before building, release after
- [x] 3.2 In `handlers.rs`, before building, check if build is already running — wait instead of duplicate
- [x] 3.3 Same for `runner.rs` `run_build_image_script()`

## 4. Installer Integration

- [x] 4.1 In `scripts/install.sh`, after binary install, add `tillandsias init &` background spawn with log message
- [x] 4.2 In `build.sh --install`, post-install message not needed — dev builds already have the image

## 5. Verification

- [x] 5.1 `cargo check --workspace` passes
- [x] 5.2 Test: `tillandsias init` builds forge image
- [x] 5.3 Test: run two `tillandsias init` simultaneously, second waits for first

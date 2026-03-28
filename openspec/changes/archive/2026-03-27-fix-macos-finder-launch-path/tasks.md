# Tasks

- [x] Diagnose: build, install, launch from Finder, read logs
- [x] Create OpenSpec artifacts
- [x] Add PATH augmentation to `build-image.sh` (macOS only, Linux unaffected)
- [x] Add `PODMAN` variable to `build-image.sh` that uses `$PODMAN_PATH` env or resolves absolute path
- [x] Replace bare `podman` calls in `build-image.sh` with `$PODMAN`
- [x] Pass `PODMAN_PATH` env var from `handlers.rs` when spawning build-image.sh
- [x] Pass `PODMAN_PATH` env var from `runner.rs` when spawning build-image.sh
- [x] Verify: rebuild, reinstall, launch from Finder, check logs
- [x] Run tests: `cargo test --workspace`

## 1. Logging — add spec fields to tracing spans

- [x] 1.1 Add `spec` field to `#[instrument]` on `handle_attach_here()` in handlers.rs
- [x] 1.2 Add `spec` field to `#[instrument]` on `handle_stop()` in handlers.rs
- [x] 1.3 Add `spec` field to `#[instrument]` on `handle_destroy()` in handlers.rs
- [x] 1.4 Add `spec` field to key `info!`/`error!` events in handlers.rs (build, launch, security)
- [x] 1.5 Add `spec` field to key events in runner.rs (CLI attach, image build)
- [x] 1.6 Add `spec` field to key events in event_loop.rs (container state changes)
- [x] 1.7 Add `spec` field to key events in init.rs (first-run setup)

## 2. Code annotations — module headers

- [x] 2.1 Add `@trace` to src-tauri/src/handlers.rs module doc
- [x] 2.2 Add `@trace` to src-tauri/src/launch.rs module doc
- [x] 2.3 Add `@trace` to src-tauri/src/runner.rs module doc
- [x] 2.4 Add `@trace` to src-tauri/src/event_loop.rs module doc
- [x] 2.5 Add `@trace` to src-tauri/src/embedded.rs module doc
- [x] 2.6 Add `@trace` to src-tauri/src/secrets.rs module doc
- [x] 2.7 Add `@trace` to src-tauri/src/build_lock.rs module doc
- [x] 2.8 Add `@trace` to src-tauri/src/init.rs module doc
- [x] 2.9 Add `@trace` to src-tauri/src/desktop.rs module doc
- [x] 2.10 Add `@trace` to src-tauri/src/menu.rs module doc
- [x] 2.11 Add `@trace` to crates/tillandsias-podman/src/lib.rs module doc
- [x] 2.12 Add `@trace` to crates/tillandsias-podman/src/launch.rs module doc
- [x] 2.13 Add `@trace` to crates/tillandsias-scanner/src/lib.rs module doc
- [x] 2.14 Add `@trace` to crates/tillandsias-core/src/container_profile.rs module doc

## 3. Code annotations — critical blocks

- [x] 3.1 Add `@trace` to security flags block in src-tauri/src/launch.rs
- [x] 3.2 Add `@trace` to GPU passthrough block in src-tauri/src/launch.rs
- [x] 3.3 Add `@trace` to volume mount block in src-tauri/src/launch.rs
- [x] 3.4 Add `@trace` to FD sanitization block in crates/tillandsias-podman/src/lib.rs
- [x] 3.5 Add `@trace` to container profile definitions in crates/tillandsias-core/src/container_profile.rs
- [x] 3.6 Add `@trace` to image tag derivation in handlers.rs
- [x] 3.7 Add `@trace` to singleton guard in build_lock.rs
- [x] 3.8 Add `@trace` to keyring operations in secrets.rs
- [x] 3.9 Add `@trace` to embedded source extraction in embedded.rs
- [x] 3.10 Add `@trace` to tokio::select! event loop in event_loop.rs

## 4. Bash script annotations

- [x] 4.1 Add `@trace` to scripts/build-image.sh (nix-builder, default-image)
- [x] 4.2 Add `@trace` to build.sh (dev-build)
- [x] 4.3 Add `@trace` to scripts/bump-version.sh (versioning)
- [x] 4.4 Add `@trace` to scripts/fetch-debug-source.sh (knowledge-source-of-truth)

## 5. OpenSpec skill patch

- [x] 5.1 Patch openspec-apply-change SKILL.md to instruct adding @trace on implementation

## 6. Verify

- [ ] 6.1 Run `grep -r "@trace" --include="*.rs" --include="*.sh" | wc -l` to confirm coverage
- [ ] 6.2 Run `./build.sh --check` to confirm no compilation impact
- [ ] 6.3 Verify a sample log output includes the spec field

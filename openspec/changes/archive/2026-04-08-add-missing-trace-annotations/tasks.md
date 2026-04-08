# Tasks: Add Missing @trace Annotations

- [x] Read each file to understand what spec it implements
- [x] Add `@trace spec:update-system` to `update_cli.rs` (3 traces)
- [x] Add `@trace spec:podman-orchestration` to `events.rs` (2 traces)
- [x] Add `@trace spec:cli-mode` to `cleanup.rs` (3 traces)
- [x] Add `@trace spec:update-system` to `updater.rs` (3 traces)
- [x] Add `@trace spec:singleton-guard` to `singleton.rs` (2 traces)
- [x] Add `@trace spec:remote-projects, spec:gh-auth-script` to `github.rs` (3 traces)
- [x] Verify `build_lock.rs` already traced (confirmed: `spec:build-lock`)
- [x] Verify `embedded.rs` already traced (confirmed: 8+ traces)
- [x] Confirm `machine.rs` and `web.rs` do not exist
- [x] Run `cargo test --workspace` to verify no breakage
- [x] Create OpenSpec change artifacts

# Tasks: persistent-git-service

## Implementation
- [x] Remove the per-forge-exit `stop_git_service` trigger in `src-tauri/src/event_loop.rs:608-616`; replace with a comment explaining the new lifetime model and where cleanup actually happens
- [x] Update `handlers::shutdown_all` (`src-tauri/src/handlers.rs:2823`) to collect git-service project names from `state.running` rows with `container_type == GitService`, not from "projects with active forges"
- [x] Verify `EnclaveCleanupGuard` in `runner.rs:26` still stops git-service in CLI mode (unchanged — CLI is one-shot)
- [x] Add `// @trace spec:git-mirror-service, spec:persistent-git-service` at both touched sites

## Verify
- [x] `cargo check --workspace` clean
- [x] Manual (tray): launch project A's forge, close it, relaunch. Second launch's log should NOT show "Starting git service container" — `ensure_git_service_running` should early-return on the state.running check
- [x] Manual (tray): exit tray with two projects' git-services running. Confirm `podman ps -a` shows zero `tillandsias-git-*` containers afterward
- [x] Manual (CLI): `tillandsias <project> --bash`, exit. Confirm CLI still tears down its git-service via `EnclaveCleanupGuard`

## Cheatsheet
- [x] Update `docs/cheatsheets/enclave-architecture.md` to document the new lifetime model: proxy/inference/git-service all tray-session-scoped (with project scope on git-service)

## Trace + commit
- [x] OpenSpec validate
- [x] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Apersistent-git-service&type=code`

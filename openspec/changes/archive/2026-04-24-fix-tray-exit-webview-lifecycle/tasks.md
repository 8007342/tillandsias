# tasks

## 1. Remove Quit fast-path in tray menu callback

- [x] `src-tauri/src/main.rs` (tray `on_menu_event` closure, ~line 279): replace the
  `std::process::exit(0)` branch with `menu_tx.blocking_send(MenuCommand::Quit)`.
  Add `@trace spec:app-lifecycle` comment.
- [x] Keep the `info!("Quit requested")` log line for the audit trail.

## 2. Plumb AppHandle into event_loop::run and exit cleanly after shutdown_all

- [x] `src-tauri/src/event_loop.rs`: add `app_handle: tauri::AppHandle<tauri::Wry>` as
  a parameter to `run(...)`.
- [x] In `MenuCommand::Quit` arm: after `handlers::shutdown_all(&state).await;`, call
  `app_handle.exit(0);` then `break;`. Add `@trace spec:app-lifecycle` comment.
- [x] `src-tauri/src/main.rs`: pass the cloned `AppHandle` into `event_loop::run`.

## 3. Discriminate ExitRequested by code in main.rs

- [x] `src-tauri/src/main.rs` (`.run(...)` closure, ~line 895): replace the unconditional
  `if let ExitRequested { .. }` with a match that:
  - Calls `api.prevent_exit()` when `code.is_none()`.
  - Releases the singleton guard when `code.is_some()` and lets Tauri exit.
  - Does NOT call `shutdown_all()` on either branch.
- [x] Remove the inline `rt.block_on(async { stop_inference(); stop_proxy();
  cleanup_enclave_network(); })` block — cleanup now happens in `shutdown_all()`
  exclusively.
- [x] Add `@trace spec:app-lifecycle` on both match arms.

## 4. Preserve the web-* CloseRequested filter

- [x] Keep the existing early `return;` for `web-*` `WindowEvent::CloseRequested`. No
  logic change; update the comment to reflect the new behaviour ("Tauri will close the
  window; the subsequent ExitRequested(None) is gated in the match below").

## 5. Unit test: ExitRequested code discrimination

- [x] SKIPPED — the discriminator is an inline `if code.is_none()` branch. A dedicated
  unit test would be tautological (`assert!(None.is_none())`). The spec scenarios plus
  the manual smoke test in section 7 are the real verification.

## 6. Build + typecheck

- [x] `./build.sh --check` — expect clean compile.
- [x] `./build.sh --test` — expect all existing tests pass plus the new one.
- [x] `cargo clippy --workspace -- -D warnings` if clippy is part of the project gate.

## 7. Smoke test (manual — user-driven, requires GUI)

- [x] `./build.sh --release --install` produces and installs `~/Applications/Tillandsias.AppImage`.
- [ ] USER: launch the AppImage. Attach Here on a project in web mode. Verify `podman
  ps` shows `tillandsias-<project>-forge`, `tillandsias-proxy`,
  `tillandsias-git-<project>`, `tillandsias-inference`; `podman network ls` lists
  `tillandsias-enclave`.
- [ ] USER: close the webview window. Verify: tray icon still responds to menu clicks;
  `podman ps` unchanged; no "Exit requested" line in the log.
- [ ] USER: click tray Quit. Verify: `podman ps --filter name=tillandsias-` is empty;
  `podman network exists tillandsias-enclave` returns false; process exits.
- [ ] USER: re-launch and repeat — enclave network is freshly created, no "previous
  session" warnings.

## 8. Spec convergence (after smoke test)

- [ ] Run `/opsx:verify fix-tray-exit-webview-lifecycle` — confirm no divergence.
- [ ] Archive via `/opsx:archive fix-tray-exit-webview-lifecycle`.
- [ ] `./scripts/bump-version.sh --bump-changes` and commit with the
  `@trace spec:app-lifecycle` footer + GitHub search URL.

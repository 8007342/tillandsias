## Why

Regression discovered after `tray-aware-cli-and-webview-lifecycle` landed: the tray quit
path and the webview close path both leave containers running and the enclave network
attached, contrary to the specs already in `openspec/specs/app-lifecycle/` and
`openspec/specs/opencode-web-session/`.

Observed behaviour (v0.1.159.x):

- Clicking tray **Quit** calls `std::process::exit(0)` directly in a "fast-path" at
  `src-tauri/src/main.rs:279-284`. That bypasses `handlers::shutdown_all()` (which owns
  the orphan sweep + enclave network teardown). Every `tillandsias-*-forge` container
  stays running. On the next launch the enclave network cannot be destroyed because
  containers are still attached to it.
- Closing the last `web-*` webview window fires `RunEvent::ExitRequested { code: None }`.
  The current handler does partial cleanup (`stop_inference` / `stop_proxy` /
  `cleanup_enclave_network`) and lets the app exit — it never calls `api.prevent_exit()`.
  Result: closing an OpenCode Web window closes the tray, contradicting the spec
  "Webview close does not terminate the tray".
- The partial cleanup in the `ExitRequested` branch does not touch forge or
  OpenCode Web containers, so even on that code path containers leak.

The specs are correct. The code diverges. Convergence requires routing every exit path
through `shutdown_all()` and gating auto-exit at `RunEvent::ExitRequested`.

## What Changes

- **Remove the Quit fast-path.** `main.rs` tray menu handler dispatches `MenuCommand::Quit`
  through the existing channel instead of calling `std::process::exit(0)`. The event loop's
  Quit arm remains the single owner of cleanup — it already calls `shutdown_all()`.
- **Event loop calls `app_handle.exit(0)` after `shutdown_all()`.** `event_loop::run`
  gains an `AppHandle` parameter so the Quit arm can trigger a clean Tauri exit once
  containers and the enclave network have been torn down.
- **`RunEvent::ExitRequested` discriminates on `code`.** When `code.is_none()` the
  handler calls `api.prevent_exit()` — the tray icon is the app's identity, not any
  window. When `code.is_some()` (our explicit `app.exit(0)` from the event loop) the
  handler releases the singleton and lets Tauri exit. `shutdown_all()` is NOT re-run on
  this branch; the event loop already ran it exactly once.
- **Webview `CloseRequested` filter stays.** The existing `return;` for `web-*` labels is
  already correct — Tauri closes the window by default, and with `prevent_exit()` guarding
  auto-exit the tray survives.
- **Capability note:** nothing is removed from the `app-lifecycle` or `opencode-web-session`
  specs. One new requirement is added to `app-lifecycle` making the `code`-discrimination
  rule explicit, so any future regression of this shape is caught by `/opsx:verify`.

## Capabilities

### Modified Capabilities

- `app-lifecycle`: adds "ExitRequested discriminates on code" requirement so the
  runtime contract is explicit.

## Impact

- **Rust**: `src-tauri/src/main.rs` (QUIT fast-path, `RunEvent::ExitRequested` handler),
  `src-tauri/src/event_loop.rs` (accept `AppHandle`, call `app.exit(0)` in Quit arm).
  `handlers::shutdown_all()` itself does not change — it is already correct.
- **No spec behavioural removals.** Existing scenarios ("Webview close does not terminate
  the tray", "No web containers survive app exit", "Orphan web containers are swept on
  shutdown") remain and are exercised by the smoke test in the task list.
- **No schema/config/asset changes.**
- **Tests**: headless-CI-compatible unit check for the `ExitRequested` code discrimination
  is added. Full lifecycle verification is the smoke-test task.

# Design: fix-tray-exit-webview-lifecycle

## Context

The `tray-aware-cli-and-webview-lifecycle` change archived on 2026-04-23 added the
`RunEvent::WindowEvent { CloseRequested }` filter for `web-*` labels in `main.rs`. Under
the assumption that this filter also prevented Tauri's "last window closed → exit"
auto-exit, the `ExitRequested` branch was left doing narrow cleanup
(`stop_inference` / `stop_proxy` / `cleanup_enclave_network`) and exiting unconditionally.
That assumption was wrong: the filter suppresses our own observation of the window event,
but Tauri still fires `RunEvent::ExitRequested { code: None }` when the last window
closes. The handler then happily exits.

Separately, the `main.rs` tray menu handler predates the `shutdown_all()` refactor and
calls `std::process::exit(0)` directly when the user clicks Quit. That bypasses the
`MenuCommand::Quit` path in `event_loop.rs` (which does call `shutdown_all()`), so
`shutdown_all()` never actually runs in production. Stale containers and a non-removable
enclave network are the observable consequences.

## Decisions

### Decision 1 — Single cleanup owner: `event_loop` Quit arm

`handlers::shutdown_all()` is already the correct cleanup routine (orphan sweep, network
teardown ordering, webview close, git-service/inference/proxy stop). It runs on the
tokio runtime and needs a `TrayState` reference. The event loop already owns `state` and
already calls `shutdown_all()` in its `MenuCommand::Quit` arm.

We make this the **only** path that runs `shutdown_all()`. The `RunEvent::ExitRequested`
handler does not re-run it, because:

- When `ExitRequested` fires with `code = Some(0)` after the event loop called
  `app.exit(0)`, cleanup has already happened. Re-running it is wasteful and racy.
- When `ExitRequested` fires with `code = None` (Tauri auto-exit), we want to prevent
  the exit entirely, not clean up.

### Decision 2 — `ExitRequested` gate: `api.prevent_exit()` when `code.is_none()`

Tauri v2 distinguishes explicit exits (`app.exit(n)` → `ExitRequested { code: Some(n) }`)
from framework-driven exits (last window closed → `ExitRequested { code: None }`). We use
this distinction directly:

```rust
tauri::RunEvent::ExitRequested { api, code, .. } if code.is_none() => {
    api.prevent_exit();
    return;
}
tauri::RunEvent::ExitRequested { code: Some(_), .. } => {
    // shutdown_all() already ran in the event loop; just finalize.
    singleton::release();
    let _ = shutdown_tx.blocking_send(());
}
```

Rationale: the tray icon is the app's identity. No window being open is not the same as
"the user wants to quit". The only authoritative exit trigger is the tray Quit menu
(which routes through `shutdown_all()` + `app.exit(0)`).

### Decision 3 — `event_loop::run` receives `AppHandle<Wry>`

To call `app.exit(0)` from the Quit arm without introducing a new global, we pass the
`AppHandle` into `event_loop::run`. This is a pure additive parameter — callers in
`main.rs` already have the handle in scope. The existing global `webview::APP_HANDLE` is
separate (used for off-thread webview operations) and not a substitute, since we want
an explicit owned handle on the event loop.

### Decision 4 — Keep the `web-*` `CloseRequested` `return;`

The existing early `return` in the `RunEvent::WindowEvent { CloseRequested }` branch is
still correct. Tauri's default close behaviour proceeds (the window is destroyed). The
tray survives because Decision 2 prevents the subsequent auto-exit. We do not call
`api.prevent_close()` — we do want the window to close.

### Decision 5 — Replace the Quit fast-path with a channel dispatch

```rust
if id == menu::ids::QUIT {
    info!("Quit requested");
    // Dispatch into the event loop so shutdown_all() runs on the tokio runtime.
    let _ = menu_tx.blocking_send(MenuCommand::Quit);
    return;
}
```

`blocking_send` is correct because the tray callback runs on a non-async thread. The
channel capacity (64) is ample; if the send ever failed the user would see the tray icon
not respond to Quit, and we would fall back to the next iteration of the tray menu
callback — acceptable failure mode, never silent data loss.

## Alternatives Considered

- **Keep `std::process::exit(0)` but call `shutdown_all()` synchronously from the tray
  callback.** Rejected: `shutdown_all()` is async and requires a runtime. Building one
  inside the tray callback duplicates what the event loop already does, and doubles the
  risk of the cleanup running in the wrong context.
- **Call `shutdown_all()` from the `ExitRequested` handler.** Rejected for the same
  reason — requires building a fresh runtime and gaining access to `state` from a move
  closure. Also duplicates work if the event loop already ran it.
- **Listen for `app.exit(0)` via a dedicated channel and do cleanup there.** Rejected:
  adds indirection; the event loop is already the natural owner of the cleanup step.

## Trace requirements

- `@trace spec:app-lifecycle` on the new `ExitRequested` match arms.
- `@trace spec:app-lifecycle, spec:opencode-web-session` on the Quit fast-path dispatch.
- `@trace spec:app-lifecycle` on the new `AppHandle` parameter in `event_loop::run`.

## Smoke-test plan (deferred to task execution)

1. Build debug (`./build.sh`).
2. Launch tray, attach a project in web mode, confirm `tillandsias-<project>-forge`
   running in `podman ps`.
3. Close the webview window. Verify: tray icon persists, `podman ps` still shows the
   container, `podman network exists tillandsias-enclave` returns true.
4. Click tray Quit. Verify: `podman ps` empty of `tillandsias-*`, `podman network ls`
   has no `tillandsias-enclave`, process exits 0.
5. Re-launch — the enclave network is re-created fresh, no "stale" log lines.

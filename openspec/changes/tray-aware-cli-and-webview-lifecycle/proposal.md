## Why

The v0.1.159.x attach flow works but several UX edges jar the user experience:

- The OpenCode web UI opens in the system colour scheme, even though the tray app's primary audience runs dark environments and OpenCode's own default is a light theme that feels foreign next to the forge's dark terminal output.
- Closing the embedded webview window takes the entire tray app down with it — the tray icon is not a window, yet Tauri treats the last closed window as "app done". The container, the scanner, and every other invisible piece of infrastructure all die silently.
- `tillandsias /path` forces a mutually exclusive choice: terminal attach OR tray. A natural power-user flow — open a terminal, run Tillandsias so logs are visible, then continue using the tray to manage other projects — is impossible today. `tillandsias --debug` is similarly tray-hostile when invoked from a terminal, even though a tray icon would always be useful.
- Ctrl+C in terminal mode kills the Rust process abruptly; infrastructure containers (proxy, git, inference) are swept by the crash-recovery guard on next start, but the session is noisy and the user can't see what the clean path was.
- Closing the terminal (not the process) while a Tillandsias session is running is currently fatal: the log stream producer hangs on a broken pipe and takes the tray down with it.

## What Changes

- OpenCode Web **defaults to dark theme** via the config-overlay that every forge container already consumes. System / light remain available via per-project overrides.
- Webview close is **decoupled from app exit**. Closing a `web-*` `WebviewWindow` closes only that window; the tray, scanner, event loop, and all running containers stay alive. The existing per-project "Stop" tray action and quit-tray action remain the only paths that tear down containers.
- **Tray starts alongside CLI modes when a graphical session is detected**. Both `tillandsias --debug` and `tillandsias /path` now spawn the tray icon too (in addition to CLI behaviour). On headless hosts (no `DISPLAY` / `WAYLAND_DISPLAY` on Linux, server builds on Windows) the tray is skipped and the CLI behaves exactly as it does today.
- With a path argument, the attach flow still runs in the terminal foreground (logs + opencode TUI). When the foreground opencode exits, the **tray continues to run** — the user returns to their shell with Tillandsias still managing projects in the background.
- **SIGINT (Ctrl+C) triggers a clean shutdown** on every code path — CLI-alone, CLI+tray, tray-alone — routing through the existing `shutdown_all()` so proxy/git/inference/forge containers stop gracefully and the process exits 0.
- **Broken stdout/stderr is non-fatal**. If the user closes the terminal window without signalling the process (common on macOS iTerm, Linux Konsole, Windows Terminal when the host OS lets the parent keep running), the tracing layer swallows `EPIPE`/`BrokenPipe` and the tray continues to operate through the file appender alone.

## Capabilities

### New Capabilities
- `tray-cli-coexistence`: contract for running the tray icon concurrently with CLI modes, desktop-environment detection, and broken-stream tolerance in the logging pipeline.

### Modified Capabilities
- `opencode-web-session`: default theme flipped to dark; webview-close semantics clarified (close ≠ app exit); per-project "Stop" remains the only container teardown.
- `cli-mode`: both `--debug` alone and `/path` attach modes may start the tray when a graphical session is available, and signal handling for Ctrl+C routes through `shutdown_all`.
- `app-lifecycle`: explicit SIGINT contract; webview-close is not an exit signal.

## Impact

- **Rust**: `src-tauri/src/main.rs` (mode dispatch, signal handling, Tauri `.run()` event filter), `src-tauri/src/cli.rs` (`CliMode::Attach` + `CliMode::Debug` become tray-aware variants or carry a "also start tray" flag), `src-tauri/src/runner.rs` (CLI-path attach hands off tray startup), `src-tauri/src/logging.rs` (broken-pipe tolerance on the stderr layer), new `src-tauri/src/desktop_env.rs` (or extension of `desktop.rs`) for graphical-session detection.
- **Tauri config**: no changes to `tauri.conf.json`; existing `windows: []` still correct. The `RunEvent::WindowEvent::CloseRequested` filter prevents exit for `web-*` labels.
- **Forge image**: `images/default/config-overlay/opencode/config.json` gets `"theme": "tillandsias-dark"` (or whatever key OpenCode expects — design.md resolves this). Embedded-source const updated accordingly. No Containerfile changes.
- **Docs**: `docs/cheatsheets/opencode-web.md` gains a "default theme" note and a "closing a webview" note.
- **Tests**: new unit tests for desktop-env detection, broken-pipe tolerance, and `RunEvent` handler filter. Headless-CI-compatible (no display requirement).
- **No schema / config migration** — existing user `~/.config/tillandsias/config.toml` files keep working.

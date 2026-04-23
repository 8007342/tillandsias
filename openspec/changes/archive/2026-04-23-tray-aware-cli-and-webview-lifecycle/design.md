## Context

Tillandsias today has two mutually exclusive operating modes: a Tauri-managed tray icon (`tillandsias` with no path) and a CLI runner (`tillandsias /path` or `tillandsias --debug`). The CLI runner inherits stdio for user-facing output and runs `podman run -it --rm` (or, for `--debug`, just emits logs and exits). The tray runner lives without any open window — the system tray icon is the only UI. When OpenCode Web spawned its first `WebviewWindow`, an unintended consequence surfaced: Tauri's default behaviour exits the runtime when the last window closes. Closing one webview now equals quit.

Three additional UX cuts have surfaced in user testing:

- The OpenCode TUI inside the forge looks dark; the embedded webview looks light by default. Visually inconsistent.
- A power user opens a terminal, runs `tillandsias` to see logs, and expects the tray to also be available. Today they have to choose.
- Ctrl+C in the CLI path kills the process abruptly, leaving the next session to clean up via the existing crash-recovery sweep — noisy and surprising.

This change is a coherent UX cleanup that cuts across `cli-mode`, `app-lifecycle`, and `opencode-web-session`, plus introduces a small new capability (`tray-cli-coexistence`) that owns the orthogonal "do both" plumbing.

## Goals / Non-Goals

**Goals:**

- OpenCode Web webview opens with a dark theme by default. User overrides remain possible.
- Closing a `web-*` `WebviewWindow` closes only that window. Tray + scanner + event loop + containers continue.
- When invoked from a graphical session, both `tillandsias --debug` and `tillandsias <path>` start the tray icon in addition to their CLI behaviour.
- For `tillandsias <path>`, terminal mode runs in the foreground; tray runs concurrently. When the foreground OpenCode TUI exits, the tray remains.
- SIGINT (Ctrl+C) anywhere triggers the same `shutdown_all()` path, exits cleanly with code 0.
- Closing the host terminal (without sending a signal) does not crash the process. The tray keeps running; the now-disconnected stderr layer drops writes silently and the file appender continues to receive everything.
- Headless / no-display environments fall back to today's CLI-only behaviour. CI and ssh sessions are not surprised by a tray they can never see.

**Non-Goals:**

- Configurable theme via UI (out of scope; users edit project's `.tillandsias/config.toml` if they want a different theme).
- Multi-tray-icon support per user.
- Letting webview windows persist across tray restarts.
- Supporting Windows Service mode (the headless CI fallback covers automated cases; service mode is a different design).
- Restoring a closed webview window programmatically — the user reattaches via the tray menu's "Attach Here", which already creates a fresh `WebviewWindow`.

## Decisions

### D1. Default theme = `tokyonight`, set via `tui.json` in the config overlay

OpenCode TUI/Web reads `~/.config/opencode/tui.json`. The forge image already mounts an overlay at `/home/forge/.config-overlay/`; the entrypoints symlink its files into `~/.config/`. We add `images/default/config-overlay/opencode/tui.json` with `{ "theme": "tokyonight" }`. The config overlay is read-only at the container layer, so a project that wants a different theme drops its own `~/.config/opencode/tui.json` in its workspace via the existing per-project mount.

- **Why `tokyonight` and not a custom Tillandsias palette**: `tokyonight` is OpenCode's documented example theme, recognisable, well-tuned for both web and TUI, and ships in the binary — zero supply chain to maintain. A custom theme would add ongoing burden for marginal aesthetic gain.
- **Alternative considered**: pass `--theme tokyonight` to `opencode serve`. Rejected — themes belong in user config, not invocation flags, and the same overlay strategy already governs `config.json`.

### D2. Webview close ≠ app exit, via `RunEvent::WindowEvent`

In Tauri's `app.run(|_app, event| { ... })` closure, intercept `RunEvent::WindowEvent { label, event: WindowEvent::CloseRequested { api, .. }, .. }`. If the label starts with `web-`, do **nothing** (let Tauri close the single window) and return; do **not** propagate to `RunEvent::ExitRequested`. The existing `ExitRequested` handler stays the sole place that triggers `shutdown_all()`.

- **Why intercept at `RunEvent::WindowEvent` and not `WebviewWindowBuilder::on_close_requested`**: a builder-level handler runs for that one window's close; we also want to suppress the cascade Tauri would otherwise issue. Filtering at the runtime level is the documented Tauri v2 approach for "tray-only with optional dynamic windows".
- **Alternative considered**: keep a hidden never-displayed window so the window count is never zero. Rejected — adds an invisible WebViewGTK process to every tray launch, fragile across platforms, hides intent.
- **Quit semantics preserved**: `Quit` from the tray menu still emits `MenuCommand::Quit`, which still calls `handlers::shutdown_all` and breaks out of the event loop, which still triggers `RunEvent::ExitRequested`. Nothing about the quit path changes.

### D3. Tray-aware CLI: detect a graphical session, then dual-spawn

Introduce `desktop_env::has_graphical_session() -> bool`:
- **Linux**: `DISPLAY` non-empty OR `WAYLAND_DISPLAY` non-empty.
- **macOS**: always `true` (AppKit is always available even from `/Applications`-launched terminals; if it's not, the user is on a server build and Cocoa init will fail loudly elsewhere).
- **Windows**: `cfg!(target_os = "windows")` true unless explicitly run as a service (we already `FreeConsole` only for tray-only mode; the dual-mode case keeps the console).
- **Headless override**: a new env var `TILLANDSIAS_NO_TRAY=1` forces CLI-only behaviour even when a session is present (CI escape hatch).

When `has_graphical_session()` is true and CLI mode is `Attach` or any non-exiting CLI mode, spawn a child process: `Command::new(current_exe()).args([])` (no positional path; just the bare tray invocation). The child detaches via `setsid` on Unix / `CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS` on Windows. The singleton guard ensures only one tray runs — if a tray is already up, the child exits silently within milliseconds.

- **Why a separate process and not in-process tray**: Tauri's `App::run` blocks the main thread. A CLI runner that wants to also do `podman run -it --rm` in the foreground can't share that thread. A child process is simpler and inherits all the existing tray-mode startup paths. The cost is one extra process for the duration of the CLI session.
- **Singleton dedup**: existing `singleton::try_acquire()` already covers the "tray already running" case — the child will fail to acquire and exit. The CLI parent ignores the child's exit status; whether it's "I started a tray" or "tray was already up, no-op" doesn't matter to the CLI.

### D4. SIGINT handler: route to `shutdown_all()` on every CLI path

Install a `tokio::signal::ctrl_c()` listener (or `signal_hook::iterator` on threads outside tokio) at the start of `runner::run()` that, on first SIGINT, prints a friendly "stopping…" line, awaits `handlers::shutdown_all()` against a constructed throwaway state (or a project-scoped subset), then `std::process::exit(0)`. Second SIGINT during a slow stop falls through to default termination so the user can always force-quit.

- **Why not just rely on `--rm`'s teardown**: the existing CLI flow uses `podman run -it --rm` which already cleans up the forge container. But the *enclave* (proxy, git, inference) is detached and persists across CLI exits — those need explicit teardown when the user is done. `shutdown_all()` already does this.
- **Why not unify with the tray's signal path**: the tray installs no signal handler today; Tauri's runtime handles SIGINT itself by emitting `RunEvent::ExitRequested`. The CLI process is independent and needs its own listener. Both paths converge on `handlers::shutdown_all`.

### D5. Broken-stream tolerance in the logging layer

`logging::init` builds a `tracing_subscriber::Layered` with a stderr layer and a non-blocking file layer. Today the stderr layer panics or hangs if stderr becomes a broken pipe (terminal closed). Wrap the stderr writer in a small adapter that catches `BrokenPipe`/`EPIPE` errors and quietly drops the write. The file appender is unaffected; the tray continues, just with no terminal echo.

- **Implementation**: a `MakeWriter` that wraps `std::io::stderr()` in a struct whose `write` impl matches `Err(e) if e.kind() == ErrorKind::BrokenPipe => Ok(buf.len())`. All other errors still propagate to tracing, which will report them once via its internal error channel.
- **Why not just close the stderr layer on detect**: Tauri's tracing config is built at startup; reconfiguring layers at runtime is awkward. A silent-drop adapter is the smallest change.

### D6. CLI parent waits for foreground OpenCode, then exits leaving tray running

Sequence for `tillandsias /path`:
1. Detect graphical session. If true, spawn detached tray child.
2. Run `runner::run(...)` as today: image check, enclave bring-up, `podman run -it --rm` in foreground.
3. When the foreground process exits (user quits OpenCode), CLI parent prints "OpenCode session ended. Tray is still running — open the menu to attach again." then `std::process::exit(0)`.
4. The tray child (separate process) keeps running. Its containers (proxy/git/inference) keep running. The CLI's forge container died with `--rm`.

This means the tray's `state.running` loses one tracked entry (the CLI-launched genus container). That's already handled — the existing podman-events listener detects the container exit and updates state.

## Risks / Trade-offs

- **Risk**: Detached child process leaks if parent dies before exec completes. → **Mitigation**: child uses `singleton::try_acquire()` with a stale-PID check that already exists; orphans get cleaned up on next legitimate launch.
- **Risk**: Two terminals each launching `tillandsias` racing to spawn a tray child. → **Mitigation**: singleton guard. Whoever wins gets the tray; the other's child exits silently. CLI behaviour in both terminals is unaffected.
- **Risk**: Webview-close interception breaks future genuine windows (e.g. an "About" dialog). → **Mitigation**: filter is keyed on the `web-` label prefix. Other window labels fall through to default behaviour.
- **Risk**: User on a Linux server with `DISPLAY=:0` set but no actual display (X forwarding misconfigured) sees a tray spawn that loops on icon load failures. → **Mitigation**: tray spawn errors land in the log (file appender) and exit the child non-zero. CLI parent ignores child status. Users running on real headless hosts unset `DISPLAY` already; those running with X forwarding will see a real (forwarded) tray, which is correct.
- **Risk**: `tokio::signal::ctrl_c()` and tokio runtime may not yet be initialised when the CLI runner is invoked. → **Mitigation**: install the listener inside the tokio runtime context the runner already constructs (it spawns a podman child via `tokio::process::Command`).
- **Risk**: Tombstone scope creep — once we change the SIGINT path on CLI, do we also need to change it on the tray? → **Mitigation**: explicit non-goal. Tray Ctrl+C continues via Tauri's `RunEvent::ExitRequested`. Both paths reach `shutdown_all`; nothing needs to converge.

## Migration Plan

1. Implement waves on `linux-next`, smoke-test on Linux/Fedora.
2. No user-facing migration. Users with explicit theme overrides continue to win (per-project `tui.json` mounted into the container takes precedence over the overlay default — verified by the existing config-overlay merge semantics).
3. Bump version, merge to main, release.
4. Doc update: cheatsheet adds a "default theme" + "closing the webview" section.

## Open Questions

- Should the dark-theme default also flip OpenCode CLI mode? Currently CLI runs `opencode` without `serve`, but the same `tui.json` applies. **Resolution**: yes, same overlay file affects both. Documented in cheatsheet.
- Should `--no-tray` be a CLI flag in addition to the env var? **Resolution**: env var only for v1. A CLI flag is trivial to add later if users ask.

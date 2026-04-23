Three waves. Within a wave, tasks are file-disjoint and run in parallel. Between waves, the workspace must compile and tests must pass.

Every code change carries `// @trace spec:<name>` (Rust) or `# @trace spec:<name>` (shell). Per-trace mapping:
- theme + tui.json work → `spec:opencode-web-session, spec:default-image`
- webview close interception → `spec:opencode-web-session, spec:app-lifecycle`
- desktop-env detection + tray-spawn + broken-pipe → `spec:tray-cli-coexistence`
- SIGINT handler → `spec:cli-mode, spec:app-lifecycle`

## 1. Wave 1 — Small/parallel UX fixes

- [ ] 1.1 Add `images/default/config-overlay/opencode/tui.json` containing `{ "$schema": "https://opencode.ai/tui.json", "theme": "tokyonight" }`. Register it in `src-tauri/src/embedded.rs` (new `CONFIG_OVERLAY_OPENCODE_TUI` const + a `write_lf` call inside `write_image_sources` for the same `images/default/config-overlay/opencode/` target dir). Verify the existing config-overlay symlinking in `lib-common.sh` already covers the new file (it should — the loop iterates everything in `~/.config-overlay/opencode/`).
- [ ] 1.2 In `src-tauri/src/main.rs`, extend the `.run(...)` closure to filter `tauri::RunEvent::WindowEvent { label, event: tauri::WindowEvent::CloseRequested { .. }, .. }` and **return early** when `label.starts_with("web-")`. The existing `RunEvent::ExitRequested` handler stays exactly as-is. Add `// @trace spec:opencode-web-session, spec:app-lifecycle` near the new arm.
- [ ] 1.3 Add a `BrokenPipeFilter` `MakeWriter` in `src-tauri/src/logging.rs` that wraps `std::io::stderr()`. Its `Write::write` impl returns `Ok(buf.len())` when the underlying error is `ErrorKind::BrokenPipe`; everything else passes through unchanged. Wire it into the existing stderr layer construction. Add a unit test that feeds a fake writer asserting BrokenPipe → silent success.

## 2. Wave 2 — Tray-aware CLI coexistence

- [ ] 2.1 Create `src-tauri/src/desktop_env.rs` exposing `pub fn has_graphical_session() -> bool`. Logic per design D3 (Linux DISPLAY/WAYLAND_DISPLAY env probe; macOS/Windows `true`; `TILLANDSIAS_NO_TRAY=1` env override → `false`). Add `mod desktop_env;` in main.rs. Add three unit tests covering the env-var permutations (use `temp_env::with_vars` if needed; otherwise scope env mutation manually with `unsafe`).
- [ ] 2.2 Add `src-tauri/src/tray_spawn.rs` with `pub fn spawn_detached_tray()`. Linux/macOS: `Command::new(std::env::current_exe()?).env_remove("TILLANDSIAS_NO_TRAY").process_group(0).spawn()`. Windows: similar with `CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS` flags via `windows_sys`. Pass `--tray-only` (a new no-op flag, or rely on no-args being tray-mode — check existing `cli::parse()` semantics first; if no-args is already tray mode, no flag needed). Returns `Ok(())` on spawn success, swallows errors with a `warn!` (CLI must not fail because tray failed).
- [ ] 2.3 In `src-tauri/src/main.rs`, before the CLI mode dispatch for `Attach` and inside the `Debug` mode (and any other CLI mode that should be tray-aware), call `if desktop_env::has_graphical_session() { tray_spawn::spawn_detached_tray(); }`. Confirm singleton guard handles "already running" silently. Add a friendly stdout line ("Tray launched in background — open the tray menu for project actions.") only the first time per session.
- [ ] 2.4 In `src-tauri/src/runner.rs`, install a SIGINT handler at the start of `run()` (after enclave init). Use `tokio::signal::ctrl_c()` in a spawned task that, on first receive, prints "Stopping…", awaits a minimal `shutdown_all`-like cleanup (proxy/git/inference/cleanup_enclave_network), then `std::process::exit(0)`. A second SIGINT during cleanup falls through to default (use a `Once` or `AtomicBool` to guard).
- [ ] 2.5 Verify `runner::run` exits 0 when the foreground podman child exits cleanly, and that no shutdown of infrastructure happens (the tray child owns infrastructure now). Print "OpenCode session ended — Tillandsias tray is still running." before returning.

## 3. Wave 3 — Smoke test, build, push, release

- [ ] 3.1 `toolbox run -c tillandsias cargo check --workspace && cargo test --workspace` — must be green, no new flakes.
- [ ] 3.2 `./scripts/build-image.sh forge` — confirm new `tui.json` lands in the image.
- [ ] 3.3 Reinstall locally: `./build.sh --install`.
- [ ] 3.4 Smoke matrix on Linux:
  - **A. Headless override**: `TILLANDSIAS_NO_TRAY=1 tillandsias --debug` → no tray spawned, logs to stdout, Ctrl+C exits 0.
  - **B. Debug + tray**: `tillandsias --debug` → tray icon appears, logs stream to terminal, Ctrl+C exits 0, tray remains.
  - **C. Path attach + tray**: `tillandsias /tmp/dummy-project` → tray icon appears, OpenCode TUI runs in terminal foreground, exit OpenCode → terminal returns, tray remains.
  - **D. Webview close**: open the tray webview attached to a project, close the window → tray + container persist; reopen via Attach Here works.
  - **E. Terminal close**: in a Konsole/GNOME-Terminal session, close the window without sending a signal → tray child remains alive (verify with `pgrep tillandsias`).
- [ ] 3.5 Bump VERSION monotonically (max(local build, remote build) + 1), update version on Cargo.toml/tauri.conf.json via `bump-version.sh`.
- [ ] 3.6 Commit with @trace URLs, push to linux-next, fast-forward main, push, trigger `gh workflow run release.yml -f version=...`.
- [ ] 3.7 Sync delta specs into main specs and `/opsx:archive tray-aware-cli-and-webview-lifecycle`.

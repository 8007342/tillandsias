## Phase 1: Foundation (deps, config, basic window)

- [ ] 1.1 Add `portable-pty` to `src-tauri/Cargo.toml` dependencies
- [ ] 1.2 Enable Tauri features in `src-tauri/Cargo.toml`: add `"window-create"` and `"webview-data-url"` to the tauri dependency features list (currently only `"tray-icon"` and `"image-png"`)
- [ ] 1.3 Update `src-tauri/capabilities/default.json`: add `"core:window:allow-create"`, `"core:window:allow-set-focus"`, `"core:window:allow-close"`, `"core:event:allow-emit"`, `"core:event:allow-listen"` permissions
- [ ] 1.4 Vendor xterm.js (minified bundle + CSS) and addons (fit, webgl, web-links) into `assets/frontend/vendor/`; no npm, no CDN, no build step
- [ ] 1.5 Create `assets/frontend/terminal.html` — minimal HTML shell that loads xterm.js, creates terminal instance, initializes fit addon
- [ ] 1.6 Create `assets/frontend/terminal.js` — Tauri IPC bindings: listen for `terminal:data` events, invoke `terminal_write` on user input, invoke `terminal_resize` on window resize, invoke `terminal_ready` on load
- [ ] 1.7 Create `assets/frontend/terminal.css` — terminal fills viewport, no scrollbars on body, dark background matching xterm defaults
- [ ] 1.8 Verify basic window creation: hardcode a test Tauri window in setup that loads `terminal.html` and displays an xterm.js instance (no PTY yet, just confirm rendering works)

## Phase 2: PTY Manager (terminal.rs, IPC commands)

- [ ] 2.1 Create `src-tauri/src/terminal.rs` — `PtySession` struct holding: PTY master pair (reader + writer), child process handle, window label, buffer
- [ ] 2.2 Implement `PtySession::spawn(command, args, env, cwd, size)` — uses `portable_pty::native_pty_system()` to open a PTY, spawns the child process connected to the PTY slave, returns `PtySession`
- [ ] 2.3 Implement `PtySession::read_loop(window)` — async task that reads from PTY master, batches output at ~16ms intervals, emits `terminal:data` events to the window, detects EOF and emits `terminal:exit`
- [ ] 2.4 Implement `PtySession::write(data)` — writes raw bytes to the PTY master writer
- [ ] 2.5 Implement `PtySession::resize(cols, rows)` — calls `pty.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })`
- [ ] 2.6 Implement `PtyManager` struct — `HashMap<String, PtySession>` keyed by window label, with methods: `spawn`, `write`, `resize`, `remove`, `has`
- [ ] 2.7 Register `PtyManager` as Tauri managed state (`app.manage(Mutex<PtyManager>)`)
- [ ] 2.8 Implement Tauri command `terminal_write(label: String, data: String, state: State<Mutex<PtyManager>>)` — looks up session by label, calls write
- [ ] 2.9 Implement Tauri command `terminal_resize(label: String, cols: u16, rows: u16, state: State<Mutex<PtyManager>>)` — looks up session, calls resize
- [ ] 2.10 Implement Tauri command `terminal_ready(label: String, state: State<Mutex<PtyManager>>)` — signals the read loop to begin emitting data
- [ ] 2.11 Register commands in `main.rs`: `.invoke_handler(tauri::generate_handler![terminal_write, terminal_resize, terminal_ready])`
- [ ] 2.12 Unit test: spawn a PTY running `echo hello`, verify read loop receives "hello\n" and emits EOF

## Phase 3: Frontend (xterm.js + Tauri bindings)

- [ ] 3.1 Implement `terminal.js` — on DOMContentLoaded: create `Terminal` instance, load fit addon, open terminal in container div, call fit
- [ ] 3.2 Wire xterm.js `onData` callback to invoke `terminal_write` with the current window label
- [ ] 3.3 Wire xterm.js `onResize` callback (from fit addon) to invoke `terminal_resize` with cols and rows
- [ ] 3.4 Listen for `terminal:data` Tauri event — base64-decode payload, call `terminal.write()` with decoded bytes
- [ ] 3.5 Listen for `terminal:exit` Tauri event — display "Session ended (exit code N)" in terminal, disable input
- [ ] 3.6 Send `terminal_ready` invoke after xterm.js initialization completes — this unblocks the PTY read loop
- [ ] 3.7 Handle window resize: `window.addEventListener('resize', ...)` triggers fit addon's `fit()`, which triggers `onResize`, which sends `terminal_resize`
- [ ] 3.8 Implement copy/paste: xterm.js selection API + Tauri clipboard (or browser default Ctrl+Shift+C/V)
- [ ] 3.9 Test: open window, verify xterm.js renders, type characters, confirm they echo back (requires Phase 2 PTY running `bash` or `cat`)

## Phase 4: Integration (replace open_terminal, wire handlers)

- [ ] 4.1 Pass `AppHandle` to `handle_attach_here()` — add parameter, thread it through from the event loop which receives it from main.rs setup
- [ ] 4.2 Rewrite `handle_attach_here()` — replace `open_terminal(&podman_cmd)` with: check for existing window (`app.get_webview_window(label)`), if exists call `set_focus()`, otherwise create `WebviewWindowBuilder::new()` with label, title, size, icon; then spawn PTY with podman args; wire read loop to window
- [ ] 4.3 Rewrite `handle_terminal()` — same pattern as attach_here but with fish entrypoint and `-terminal` label suffix
- [ ] 4.4 Rewrite `handle_github_login()` — same pattern with the extracted gh-auth-login.sh script
- [ ] 4.5 Wire window close event in `main.rs` `run()` callback — on `RunEvent::WindowEvent { event: WindowEvent::Destroyed, label, .. }`: look up PTY session, drop it (sends SIGHUP), remove from PtyManager, update TrayState
- [ ] 4.6 Wire PTY EOF to state update — when read loop detects EOF: remove container from `TrayState.running`, release genus from allocator, trigger menu rebuild, close window after 2-second delay
- [ ] 4.7 Delete `open_terminal()` function from handlers.rs
- [ ] 4.8 Remove platform-specific terminal detection code (ptyxis, gnome-terminal, konsole, xterm, osascript, cmd.exe)
- [ ] 4.9 Remove `LD_LIBRARY_PATH`/`LD_PRELOAD` clearing for terminal spawning (no longer needed — PTY is in-process)
- [ ] 4.10 Update `build_run_args()` — the function still builds the argument list but no longer joins them into a shell command string; return `Vec<String>` is passed directly to `PtySession::spawn`
- [ ] 4.11 Test with OpenCode: "Attach Here" → window opens → OpenCode launches inside container → full TUI works (colors, mouse, alternate screen, resize)
- [ ] 4.12 Test with vim/htop: open maintenance terminal → run vim → verify insert mode, syntax highlighting, mouse clicks, window resize
- [ ] 4.13 Test window re-focus: click "Attach Here" when window already exists → existing window gains focus, no duplicate created
- [ ] 4.14 Test window close cleanup: close window via X button → container receives SIGTERM → container stops within 10s → genus released → tray menu updated
- [ ] 4.15 Test PTY EOF cleanup: type `exit` in terminal → container exits → window closes automatically → genus released → tray menu updated
- [ ] 4.16 Test GitHub Login flow: click "GitHub Login" → window opens → gh auth login runs → user completes auth → window closes on exit

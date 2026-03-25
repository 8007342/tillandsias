## Why

Terminals are currently spawned as external processes (ptyxis, gnome-terminal, konsole, xterm) via `open_terminal()` in handlers.rs. Once spawned, the application loses all control. It cannot focus the window when the user clicks "Attach Here" a second time. It cannot detect when the user closes the terminal — only inferring exit indirectly from podman container events with variable delay. It cannot set the window title to the genus name, display a genus icon, or style the terminal to match the Tillandsias identity. Every platform needs a different terminal detection codepath, and on some (Windows) the experience is poor. The `open_terminal()` function is the single largest source of platform-specific bugs in the codebase.

Replacing external terminal spawning with Tauri-owned webview windows containing xterm.js eliminates all of these problems. Each "Attach Here" or "Maintenance" click creates a Tauri window with a full terminal emulator inside. The application owns the window lifecycle, can focus existing windows, detects exit immediately via PTY EOF, and renders identically on all platforms.

## What Changes

- **`open_terminal()` removed** — the function in `src-tauri/src/handlers.rs` (lines 50-123) is deleted entirely, along with all platform-specific terminal detection logic
- **New `terminal.rs` module** — PTY manager using `portable-pty` (wezterm's cross-platform PTY crate); spawns `podman run -it` connected to a PTY, runs an async read loop emitting data to Tauri windows, accepts write commands from JS
- **New Tauri IPC commands** — `terminal_write` (JS to Rust, user keystrokes), `terminal_resize` (JS to Rust, window resize events); PTY output flows via Tauri event emission (`terminal:data`)
- **New frontend** — `assets/frontend/` gains an xterm.js-based terminal host with Tauri IPC bindings; loaded into each Tauri window
- **`handle_attach_here()` rewritten** — instead of building a podman command string and passing it to `open_terminal()`, creates a Tauri window with a label matching the container name, spawns a PTY with the podman command, and wires IPC between xterm.js and the PTY
- **`handle_terminal()` rewritten** — same pattern for the maintenance/ground terminal
- **`handle_github_login()` rewritten** — same pattern for the GitHub auth flow
- **Window re-focus** — if a window with label `tillandsias-<project>-<genus>` already exists, `window.set_focus()` is called instead of creating a duplicate
- **Tauri config updated** — `tauri.conf.json` gets window configuration defaults; `capabilities/default.json` gets window and event permissions
- **Dependencies** — `portable-pty` added to `src-tauri/Cargo.toml`; Tauri features `window-create`, `event-emit`, `event-listen` enabled

## Capabilities

### New Capabilities
- `embedded-terminal`: Tauri webview window hosting xterm.js — full VT100/xterm emulation with copy/paste, scrollback, mouse events, alternate screen buffer, and resize propagation
- `pty-manager`: Async PTY lifecycle manager — spawn, read/write multiplexing, resize forwarding, EOF detection, and cleanup

### Modified Capabilities
- `environment-runtime`: "Attach Here" and "Terminal" actions create Tauri windows instead of spawning external terminal emulators; window close triggers container cleanup
- `tray-app`: Tray application transitions from window-less (`"windows": []`) to on-demand window creation; windows are per-environment, not global

## Impact

- **Deleted code**: `open_terminal()` function and all platform-specific terminal detection (~75 lines)
- **New files**: `src-tauri/src/terminal.rs`, `assets/frontend/terminal.html`, `assets/frontend/terminal.js`, `assets/frontend/terminal.css`
- **Modified files**: `src-tauri/src/handlers.rs` (rewrite attach/terminal/login flows), `src-tauri/src/main.rs` (register Tauri commands, manage app handle), `src-tauri/src/event_loop.rs` (window close events), `src-tauri/tauri.conf.json` (window defaults), `src-tauri/capabilities/default.json` (permissions), `src-tauri/Cargo.toml` (add portable-pty, enable Tauri features)
- **Security model unchanged**: All container security flags (--cap-drop=ALL, --userns=keep-id, --security-opt=no-new-privileges, --rm) are preserved — the PTY is a transport mechanism, not a security boundary
- **Cross-platform improvement**: One codepath for all platforms instead of four; portable-pty handles Unix PTY vs Windows ConPTY; xterm.js renders identically everywhere
- **Performance**: PTY output batched at ~16ms intervals before emission to JS (one frame at 60fps); eliminates per-byte IPC overhead

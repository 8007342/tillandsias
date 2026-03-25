## Context

Tillandsias is a tray-only application (`"windows": []` in tauri.conf.json). All terminal interaction happens through external emulators spawned by `open_terminal()`. This function detects available terminals per-platform, constructs a podman command string, and fires-and-forgets a child process. The application has no handle to the resulting window — no focus control, no close detection, no resize awareness, no visual identity.

xterm.js is the terminal emulator used by VS Code, Theia, JupyterLab, and other production-grade tools. It provides full xterm emulation (VT100, 256-color, truecolor, mouse events, alternate screen buffer) in a browser context. Tauri webviews are Chromium-based on all platforms, making xterm.js a natural fit.

`portable-pty` is the PTY abstraction extracted from the wezterm terminal emulator. It provides a single API across Unix (openpty/forkpty) and Windows (ConPTY), handling the OS-level pseudoterminal allocation that connects a spawned process to xterm.js.

## Goals / Non-Goals

**Goals:**
- "Attach Here" opens a Tauri window with a fully functional terminal running OpenCode inside a container
- Window is re-focused (not duplicated) on repeated clicks
- PTY EOF causes immediate state update (no waiting for podman events)
- Window close kills the container cleanly (SIGHUP via --init)
- Full TUI application support: OpenCode, vim, htop, less — anything that works in a normal terminal
- Per-window genus icon and title (e.g., "Aeranthos -- my-project")

**Non-Goals:**
- Tabs within a single window (one window per environment)
- Split panes or multiplexing (use tmux inside the container if needed)
- Custom shell themes or font bundling (use xterm.js defaults, user can configure later)
- Web-based remote access (windows are local Tauri webviews only)
- Replacing the tray menu (tray remains the primary interaction surface)

## Architecture

```
 Tray Menu Click                    Tauri Application
 ("Attach Here")                    (Rust + Tokio)
       |                                  |
       v                                  v
 +-----------+     MenuCommand     +-------------+
 | event_loop| ==================> | handlers.rs |
 +-----------+                     +------+------+
                                          |
                        1. Check for existing window (by label)
                        2. If exists: window.set_focus() -> done
                        3. If not: allocate genus, build podman args
                                          |
                                          v
                                   +-------------+
                                   | terminal.rs |
                                   | PtyManager  |
                                   +------+------+
                                          |
                        4. Create Tauri WebviewWindow (label = container name)
                        5. Spawn PTY: podman run -it --rm <flags> <image>
                        6. Wire IPC bridge
                                          |
                    +---------------------+---------------------+
                    |                                           |
                    v                                           v
          +-----------------+                        +-------------------+
          | PTY Read Loop   |                        | Tauri Window      |
          | (tokio task)    |                        | (WebView)         |
          |                 |  terminal:data event   |                   |
          | PTY master fd --+========================>  xterm.js         |
          |                 |                        |  terminal.write() |
          |                 |  terminal:write cmd    |                   |
          | PTY write    <--+========================+  onData callback  |
          |                 |                        |                   |
          |                 |  terminal:resize cmd   |                   |
          | PTY resize   <--+========================+  onResize cb      |
          |                 |                        |                   |
          | PTY EOF --------+---> close window       |                   |
          |                 |     update state       |                   |
          +-----------------+                        +-------------------+
```

## Decisions

### D1: portable-pty for PTY management

`portable-pty` is extracted from wezterm and handles Unix PTY (openpty, forkpty, SIGWINCH) and Windows ConPTY behind a single trait. Alternatives considered:

- `pty-process` — simpler but less mature, no Windows support
- Raw `nix::pty` — Unix only, manual signal handling
- `tokio-pty-process` — abandoned

portable-pty is the only option that satisfies the cross-platform requirement without writing platform-specific code ourselves.

### D2: xterm.js for terminal rendering

xterm.js is a full xterm emulator in JavaScript. It supports:
- VT100/xterm escape sequences (colors, cursor movement, alternate screen)
- Mouse events (needed by OpenCode, vim, htop)
- IME input (CJK character entry)
- Selection, copy/paste, scrollback buffer
- WebGL renderer addon for GPU-accelerated rendering
- Fit addon for automatic resize to container dimensions

It is the same terminal used by VS Code's integrated terminal. If it works for VS Code, it works for us.

### D3: PTY spawns `podman run -it` (interactive + TTY)

The data flow is: PTY master fd <-> PTY slave fd -> podman stdin/stdout -> container TTY.

The PTY slave becomes the stdin/stdout/stderr for the `podman run -it` process. podman's `-t` flag allocates a TTY inside the container. The PTY master fd is read/written by our async loop, which bridges to xterm.js via Tauri IPC.

This means the container process sees a real terminal (TERM=xterm-256color, proper ioctl support) even though the user is interacting through a webview.

### D4: Window labels = container names

Each Tauri window gets a label matching the container name: `tillandsias-<project>-<genus>`. This provides:

- **Deduplication**: check if window exists before creating → `app.get_webview_window(label)`
- **Targeted events**: emit PTY data only to the correct window → `window.emit("terminal:data", ...)`
- **Consistent naming**: window label, container name, and tray menu item all use the same identifier

### D5: Batched PTY output at ~16ms intervals

PTY output arrives byte-by-byte or in small chunks. Sending each chunk individually through Tauri IPC to JavaScript would create excessive overhead. Instead, the read loop accumulates output in a buffer and flushes it to the window at ~16ms intervals (one frame at 60fps).

This matches how real terminal emulators work — wezterm and alacritty both batch output before rendering.

Implementation: the read loop uses `tokio::time::interval(Duration::from_millis(16))` with `tokio::select!` to alternate between reading PTY data into a buffer and flushing the buffer to the window.

### D6: PTY EOF triggers immediate cleanup

When the container exits (user types `exit`, OpenCode quits, container crashes), the PTY master read returns EOF. The read loop detects this and:

1. Emits a `terminal:exit` event to the window (JS shows "Session ended" or auto-closes)
2. Removes the container from `TrayState.running`
3. Releases the genus allocation
4. Closes the Tauri window (after a short delay to let the user see any final output)

This is faster than waiting for podman events, which have variable latency depending on the podman event stream polling interval.

### D7: Window close sends SIGHUP to container

When the user closes the Tauri window (X button, Alt+F4), the `on_window_event` handler detects the close and:

1. Drops the PTY master fd — this sends SIGHUP to the process group
2. The `--init` flag ensures the container has a proper init process (tini) that forwards SIGHUP as SIGTERM to all children
3. `--stop-timeout=10` gives the container 10 seconds for graceful shutdown before SIGKILL
4. `--rm` ensures the container is removed after exit

This is cleaner than the current situation where closing an external terminal may or may not reach the container.

### D8: AppHandle stored for window creation

The event loop currently has no access to the Tauri `AppHandle` (needed for `WebviewWindowBuilder::new()`). The handle must be passed through to the event loop, either:

- Stored in `TrayState` (simple but couples core types to Tauri)
- Passed as a parameter to the event loop (cleaner)
- Returned as a `WindowCreate` event that main.rs handles (most decoupled)

Decision: pass the `AppHandle` to `handlers::handle_attach_here()` and let it create windows directly. The handler already knows the container name (window label) and genus (for icon/title). This keeps window creation close to the business logic that decides when to create windows.

## PTY Data Flow

```
User keystroke in browser
        |
        v
xterm.js onData("a")
        |
        v
invoke("terminal_write", { label: "tillandsias-myapp-aeranthos", data: "a" })
        |
        v  (Tauri IPC, serialized as JSON)
        |
terminal_write(label, data) in terminal.rs
        |
        v
PtyManager.write(label, data.as_bytes())
        |
        v
write() to PTY master fd
        |
        v  (kernel PTY layer)
        |
podman process reads from PTY slave fd
        |
        v
Container process (OpenCode) receives "a" on stdin


Container process writes "response\n" to stdout
        |
        v
podman process writes to PTY slave fd
        |
        v  (kernel PTY layer)
        |
PTY master fd becomes readable
        |
        v
PtyManager read loop: read into buffer
        |
        v  (batched every ~16ms)
        |
window.emit("terminal:data", base64_encoded_bytes)
        |
        v  (Tauri IPC)
        |
xterm.js terminal.write(decode(data))
        |
        v
User sees "response" rendered in the terminal
```

## IPC Protocol

Three commands, one event stream per window:

### Commands (JS -> Rust)

**`terminal_write`**
- Parameters: `label: String`, `data: String`
- Behavior: writes raw bytes to the PTY master fd for the session identified by `label`
- Error: returns error if no session exists for the label

**`terminal_resize`**
- Parameters: `label: String`, `cols: u16`, `rows: u16`
- Behavior: calls `pty.resize(PtySize { rows, cols, ... })` on the PTY master
- Error: returns error if no session exists for the label

**`terminal_ready`**
- Parameters: `label: String`
- Behavior: signals that xterm.js has initialized and the PTY read loop should begin emitting data; prevents data loss during window load
- Error: returns error if no session exists for the label

### Events (Rust -> JS)

**`terminal:data`**
- Payload: `{ data: String }` (base64-encoded bytes)
- Emitted to: specific window by label
- Frequency: batched at ~16ms intervals

**`terminal:exit`**
- Payload: `{ code: Option<i32> }` (exit code if available)
- Emitted to: specific window by label
- Frequency: once, when PTY EOF is detected

## Window Lifecycle

```
                    Menu Click
                        |
                        v
              +-------------------+
              | Window exists?    |
              | (get_webview_     |
              |  window(label))   |
              +--------+----------+
                   yes |    | no
                       v    v
              focus()   create_window()
              done      load frontend
                            |
                            v
                   xterm.js initializes
                   sends terminal_ready
                            |
                            v
                   PTY spawned
                   read loop starts
                   data flows
                            |
                     +------+------+
                     |             |
                     v             v
              PTY EOF         Window closed
              (container      (user action)
               exited)              |
                     |              v
                     v         Drop PTY master
              emit exit event  (SIGHUP -> container)
              close window          |
                     |              v
                     v         Wait for container exit
              Remove from      Remove from state
              state, release   Release genus
              genus
```

## Window Configuration

Each window is created with `WebviewWindowBuilder`:

- **Label**: `tillandsias-<project>-<genus>` (same as container name)
- **Title**: `<Genus Display Name> -- <project-name>` (e.g., "Aeranthos -- my-project")
- **Size**: 960x640 default, resizable, minimum 480x320
- **URL**: `index.html` (the frontend dist, which loads xterm.js)
- **Decorations**: true (native title bar)
- **Visible**: true
- **Focused**: true
- **Icon**: genus-specific PNG from svg-icon-pipeline (when available), falling back to app icon

The `index.html` receives the window label through Tauri's window label API (`getCurrent().label`) and uses it to scope all IPC calls.

## Performance Strategy

### PTY Read Batching

The naive approach — emit every PTY read chunk immediately — creates one IPC round-trip per chunk. For a command like `cat large-file.txt`, this could be thousands of small IPC calls per second.

The batching strategy:

```
loop {
    select! {
        // Read PTY data into buffer (non-blocking)
        bytes = pty_reader.read(&mut buf) => {
            output_buffer.extend(&buf[..bytes]);
        }

        // Flush buffer to window every 16ms
        _ = flush_interval.tick() => {
            if !output_buffer.is_empty() {
                window.emit("terminal:data", base64(&output_buffer));
                output_buffer.clear();
            }
        }

        // PTY closed
        Err(_) = pty_reader.read() => {
            // flush remaining, emit exit
            break;
        }
    }
}
```

### Serialization

PTY output is raw bytes that may contain partial UTF-8 sequences (e.g., a multi-byte emoji split across reads). Sending raw bytes through JSON-based Tauri IPC requires encoding. Options:

- **Base64**: ~33% overhead, safe, simple decode in JS
- **Array of numbers**: verbose JSON, higher overhead
- **String with lossy UTF-8**: corrupts binary data

Decision: base64 encoding. The overhead is acceptable — even at 100MB/s PTY throughput (unrealistic), the 33% overhead is dwarfed by xterm.js rendering time.

### xterm.js Addons

- **xterm-addon-fit**: auto-resize terminal to window dimensions — essential
- **xterm-addon-webgl**: GPU-accelerated rendering — enabled when available, falls back to canvas
- **xterm-addon-web-links**: clickable URLs — nice to have, low cost

## Cross-Platform Notes

### Linux
- PTY: `portable-pty` uses `openpty()` + `forkpty()` from libc
- Signals: SIGHUP on PTY close, forwarded by `--init` (tini)
- Tauri webview: WebKitGTK (not Chromium) — xterm.js works, but WebGL addon may not; canvas fallback is fine

### macOS
- PTY: same Unix PTY syscalls as Linux
- Signals: same SIGHUP behavior
- Tauri webview: WKWebView (Safari engine) — xterm.js works, WebGL addon works
- Note: podman on macOS runs through podman machine (Linux VM); PTY connects to the `podman` CLI on the host, which proxies to the VM

### Windows
- PTY: `portable-pty` uses Windows ConPTY API (Windows 10 1809+)
- Signals: ConPTY sends CTRL_CLOSE_EVENT on handle close; container receives SIGTERM via podman's signal forwarding
- Tauri webview: WebView2 (Chromium-based) — xterm.js works perfectly, WebGL addon works
- Note: podman on Windows also runs through podman machine (WSL2 or Hyper-V)

## Security Model Preservation

This change does NOT alter the container security model. The PTY is purely a transport mechanism between xterm.js and the podman process. All security flags applied by `build_run_args()` are unchanged:

| Flag | Purpose | Status |
|------|---------|--------|
| `--cap-drop=ALL` | Drop all Linux capabilities | Unchanged |
| `--security-opt=no-new-privileges` | No privilege escalation | Unchanged |
| `--userns=keep-id` | Map host UID into container | Unchanged |
| `--security-opt=label=disable` | Disable SELinux relabeling | Unchanged |
| `--rm` | Ephemeral container | Unchanged |
| `--init` | Proper signal handling | Unchanged |
| `--stop-timeout=10` | Graceful shutdown window | Unchanged |

Volume mounts remain identical. The PTY replaces the external terminal emulator, not the container.

The Tauri IPC surface is scoped per-window — a window can only write to its own PTY session (keyed by label). There is no cross-window PTY access.

## Dependency Assessment

### portable-pty

- **Source**: `https://github.com/wezterm/wezterm` (extracted crate)
- **Maintenance**: actively maintained as part of wezterm
- **Size**: ~5k lines, no transitive dependencies beyond libc/winapi
- **License**: MIT
- **Risk**: low — battle-tested in wezterm (tens of thousands of users)

### xterm.js

- **Source**: `https://github.com/xtermjs/xterm.js`
- **Maintenance**: actively maintained, Microsoft-backed (used in VS Code)
- **Size**: ~200KB minified + gzip
- **License**: MIT
- **Bundling**: vendored into `assets/frontend/` (no CDN dependency, no npm at build time)
- **Risk**: low — used by VS Code, JupyterLab, Theia, Azure Cloud Shell

Both dependencies are MIT-licensed and widely deployed. Neither introduces supply chain risk beyond what Tauri itself already carries.

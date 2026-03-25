## ADDED Requirements

### Requirement: PTY sessions managed per window label

The application SHALL maintain a `PtyManager` that maps window labels to active PTY sessions. Each session owns a PTY master pair (reader + writer) and the spawned child process.

#### Scenario: Spawn PTY for new environment

- **WHEN** a new terminal window is created for a container
- **THEN** a PTY is allocated via `portable-pty`, the podman command is spawned as a child process connected to the PTY slave, and the session is registered in `PtyManager` keyed by the window label

#### Scenario: Write user input to PTY

- **WHEN** the frontend invokes `terminal_write` with a window label and keystroke data
- **THEN** the PTY manager looks up the session by label and writes the raw bytes to the PTY master fd
- **WHEN** the label does not match any active session
- **THEN** an error is returned and no data is written

#### Scenario: Resize PTY on window resize

- **WHEN** the frontend invokes `terminal_resize` with a window label, column count, and row count
- **THEN** the PTY manager looks up the session by label and calls `pty.resize()` with the new dimensions, causing the kernel to send SIGWINCH to the child process group

#### Scenario: Session removed on cleanup

- **WHEN** a PTY session ends (EOF detected or window closed)
- **THEN** the session is removed from `PtyManager`, the PTY master fd is closed, and the child process handle is dropped

### Requirement: Async PTY read loop with output batching

Each PTY session SHALL run an async read loop as a tokio task that reads from the PTY master and emits data to the associated Tauri window.

#### Scenario: PTY output delivered to window

- **WHEN** the container process writes to stdout/stderr
- **THEN** the data traverses: container stdout -> podman -> PTY slave -> PTY master -> read loop buffer -> base64 encode -> Tauri `terminal:data` event -> xterm.js

#### Scenario: Output batched at frame rate

- **WHEN** PTY output arrives continuously (e.g., `cat large-file.txt`)
- **THEN** the read loop accumulates data in a buffer and flushes to the window at approximately 16ms intervals (60fps), sending one `terminal:data` event per flush rather than one per read syscall

#### Scenario: Read loop waits for frontend ready signal

- **WHEN** a PTY session is spawned and the read loop starts
- **THEN** the read loop buffers PTY output but does NOT emit `terminal:data` events until it receives the `terminal_ready` signal from the frontend, preventing data loss during xterm.js initialization

#### Scenario: PTY EOF detected

- **WHEN** the PTY master read returns zero bytes or an error (child process exited)
- **THEN** the read loop flushes any remaining buffered data, emits a final `terminal:data` event with the buffer contents, emits a `terminal:exit` event with the child exit code (if available), and terminates the task

### Requirement: Cross-platform PTY allocation

The PTY manager SHALL use `portable-pty` to abstract platform differences in pseudoterminal allocation.

#### Scenario: Linux PTY

- **WHEN** running on Linux
- **THEN** `portable-pty` uses `openpty()` and `forkpty()` from libc to allocate a Unix pseudoterminal pair

#### Scenario: macOS PTY

- **WHEN** running on macOS
- **THEN** `portable-pty` uses the same Unix PTY syscalls as Linux (macOS has full POSIX PTY support)

#### Scenario: Windows PTY

- **WHEN** running on Windows 10 (1809 or later)
- **THEN** `portable-pty` uses the Windows ConPTY API to allocate a pseudoconsole

### Requirement: PTY security scoping

Each PTY session SHALL be scoped to exactly one window and one container. No cross-session access is possible.

#### Scenario: Write scoped to session

- **WHEN** the `terminal_write` command is invoked with a label
- **THEN** data is written only to the PTY master for that specific label; there is no mechanism to address a different session's PTY

#### Scenario: Session isolation

- **WHEN** multiple terminal windows are open simultaneously
- **THEN** each window's IPC calls (write, resize, ready) operate exclusively on its own PTY session; a bug or exploit in one window's frontend cannot affect another window's PTY

### Requirement: Graceful PTY teardown

PTY sessions SHALL be cleaned up deterministically on all exit paths.

#### Scenario: Normal exit (container exits)

- **WHEN** the container process exits normally (exit code 0)
- **THEN** PTY EOF is detected, session is removed from PtyManager, window is closed after a brief delay

#### Scenario: Abnormal exit (container crashes)

- **WHEN** the container process exits abnormally (non-zero exit code, OOM kill, SIGKILL)
- **THEN** PTY EOF is detected identically to normal exit, the exit code is reported in the `terminal:exit` event, and cleanup proceeds the same way

#### Scenario: Window closed while container running

- **WHEN** the user closes the terminal window while the container is still running
- **THEN** the PTY master fd is dropped (kernel sends SIGHUP to the process group), the container's init process forwards SIGHUP as SIGTERM, the container has `--stop-timeout=10` seconds for graceful shutdown, and `--rm` removes the container after exit

#### Scenario: Application shutdown

- **WHEN** the Tillandsias application exits (Quit from tray, system shutdown)
- **THEN** all active PTY sessions are torn down: PTY masters dropped, containers receive SIGHUP/SIGTERM, `shutdown_all()` runs `podman stop` as a backstop for any containers that survive the signal

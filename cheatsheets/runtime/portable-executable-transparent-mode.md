---
tags: [portable-executable, headless, tray, gtk, runtime]
languages: [bash, rust]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://github.com/tauri-apps/tauri
  - https://man7.org/linux/man-pages/man2/kill.2.html
  - https://gtk-rs.org/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
## Provenance

- https://github.com/tauri-apps/tauri — Reference for multi-mode app architectures
- https://man7.org/linux/man-pages/man2/kill.2.html — Signal handling documentation
- https://gtk-rs.org/ — GTK4 Rust bindings
- **Last updated:** 2026-05-05

## Portable Executable Transparent Mode

**Use when:** Building a Linux portable executable (musl binary) that works both as a headless daemon and a system tray application, automatically detecting the environment.

### Overview

The tillandsias-headless binary implements a three-tier mode system:

1. **Automatic Detection (default)** — No flags
   - Checks if GTK4 is available via `pkg-config --exists gtk4`
   - If available AND tray feature compiled: launches tray mode
   - If not available OR tray feature missing: displays usage info

2. **Explicit Headless** — `--headless` flag
   - Runs without GTK dependency
   - Suitable for CI/CD, automation, server deployments
   - JSON event output to stdout
   - @trace spec:headless-mode

3. **Explicit Tray** — `--tray` flag (requires tray feature)
   - Requires gtk4 and libadwaita features compiled
   - Spawns headless subprocess
   - Manages UI + subprocess lifecycle
   - @trace spec:tray-ui-integration

### Compilation Modes

```bash
# Headless only (always works, no GTK dependency)
cargo build -p tillandsias-headless

# With optional tray support
cargo build -p tillandsias-headless --features tray

# Full workspace with tray
cargo build --workspace --features tray
```

### Usage Patterns

**Server / CI / Headless Automation:**
```bash
# Explicit headless mode (no GTK required)
tillandsias --headless /path/to/config.toml

# Or implicit (when GTK not available or feature not compiled)
tillandsias
```

**Desktop / System Tray (with GTK available):**
```bash
# Explicit tray mode
tillandsias --tray /path/to/config.toml

# Or implicit auto-detection (if tray feature compiled + GTK available)
tillandsias
```

### Transparent Mode Detection (Phase 3)

**Task 12: Environment Auto-Detection**
- Binary calls `is_gtk_available()` via `pkg-config --exists gtk4`
- If GTK found AND tray feature compiled: re-execs as `--headless` + spawns tray manager
- If GTK not found OR tray feature missing: prints usage and exits

**Implementation details:**
- `pkg-config` check is zero-cost on GTK-less systems (fails fast)
- No runtime GTK imports unless tray feature compiled
- Binary is always portable (single musl binary)
- Feature gating ensures headless-only builds have zero GTK dependencies

**Task 13: Explicit Tray Flag**
- `--tray` flag forces tray mode
- Returns error if tray feature not compiled
- Useful for testing or explicit deployment

**Task 14: Test Transparent Mode**
```bash
# Build without tray feature
cargo build -p tillandsias-headless

# Run without flags — should show usage and exit
./target/debug/tillandsias-headless

# Explicitly request headless
./target/debug/tillandsias-headless --headless
# Output: JSON events to stdout

# Try to use tray (should fail with helpful error)
./target/debug/tillandsias-headless --tray
# Error: --tray requires the 'tray' feature to be compiled
```

### Headless Mode (Phase 3-5)

**JSON Event Output:**
```json
{"event":"app.started","timestamp":"2026-05-05T18:17:45.413Z"}
{"event":"containers.running","count":3}
{"event":"containers.stopped","count":2}
{"event":"app.stopped","exit_code":0,"timestamp":"2026-05-05T18:18:17.512Z"}
```

**Signal Handling (Phase 5):**
- Listens for SIGTERM and SIGINT
- Sets channel-based shutdown signal (async-safe)
- Gracefully stops all containers (30s timeout)
- Escalates to SIGKILL if containers don't stop
- Exits with code 0 on success, 143 if force-killed

### Tray Mode (Phase 4)

**Subprocess Management:**
- Re-execs self with `--headless` flag to get headless subprocess
- Spawns GTK4 window with project info and container status
- Forwards SIGTERM/SIGINT to headless child
- Cleans up child on window close
- Exit code propagates from child

**GTK Integration:**
- Uses libadwaita for modern UI
- Shows project path, container count, recent events
- Simple log viewer with JSON event stream
- Minimize-to-tray support (GTK4 hide-on-close)
- System tray icon (via StatusIcon or Indicator library)

### Signal Handling (Phase 5, Tasks 21-24)

**Task 21: Async Graceful Shutdown**
- Implemented as async function with 30s timeout
- Calls `PodmanClient::stop_container(name, timeout_secs=10)`
- Returns Result allowing error propagation

**Task 22: Signal Handler Thread**
- Dedicated OS thread listening to SIGTERM/SIGINT
- Communicates with async runtime via tokio::sync::mpsc channel
- Spawns async task on runtime to send shutdown message

**Task 23: Verify 30s Timeout**
```bash
# Send SIGTERM and measure shutdown time
timeout 35 tillandsias --headless &
PID=$!
sleep 0.5
kill -TERM $PID
wait $PID
# Graceful shutdown should complete in ~30s
```

**Task 24: SIGKILL Fallback**
- If containers still running after 30s: escalate to `kill_container(name, Some(SIGKILL))`
- Process exits with code 143 if force-killed
- Logs "would escalate to SIGKILL" in graceful shutdown sequence

### Testing

```bash
# Compile tests
cargo test -p tillandsias-headless --lib

# Run signal handling tests (Phase 5)
cargo test -p tillandsias-headless signal_handling

# Run with timeout (demonstrates 30s shutdown)
timeout 35 ./target/debug/tillandsias-headless --headless &
sleep 0.5
kill -TERM $!
wait
```

### Related Specs

- @trace spec:linux-native-portable-executable — Overall portable executable goal
- @trace spec:headless-mode — Headless daemon mode
- @trace spec:tray-ui-integration — GTK4 tray UI
- @trace spec:signal-handling — Signal forwarding and graceful shutdown
- @trace spec:transparent-mode-detection — Auto-detection logic
- @trace spec:tray-subprocess-management — Subprocess lifecycle

### Related Cheatsheets

- `runtime/linux-signal-handling.md` — POSIX signal fundamentals
- `build/cargo-feature-flags.md` — Feature compilation
- `utils/musl-portable-binary.md` — Static linking for portability

<!-- @trace spec:filesystem-scanner -->
## Status

status: active

## Requirements

### Requirement: OS-native event-driven watching
The filesystem scanner MUST use OS-native file event mechanisms (inotify on Linux, FSEvents on macOS, ReadDirectoryChangesW on Windows) via the `notify` crate's `RecommendedWatcher` and MUST NOT use polling loops of any kind.

#### Scenario: Project directory created on Linux
- **WHEN** a user creates a new directory under the watch path on Linux
- **THEN** the scanner MUST detect the change via inotify and emit a project discovery event within the debounce window

#### Scenario: Project directory created on macOS
- **WHEN** a user creates a new directory under the watch path on macOS
- **THEN** the scanner MUST detect the change via FSEvents (the default backend for `RecommendedWatcher` on macOS) and emit a project discovery event within the debounce window

#### Scenario: No changes occurring
- **WHEN** no filesystem changes have occurred
- **THEN** the scanner MUST consume zero CPU cycles (blocked on OS event wait)

#### Scenario: inotify watch limit exhausted on Linux
- **WHEN** the system's `fs.inotify.max_user_watches` limit is reached and the scanner cannot register new watches
- **THEN** the scanner MUST log a warning indicating the watch limit is exhausted and continue operating with existing watches. Depth-2 scanning minimizes the number of watches required, but systems with very low limits or many concurrent inotify consumers may still hit the cap.

### Requirement: Debounced event batching
The scanner MUST debounce rapid filesystem events into batched project state updates with a configurable delay (project default: 2000ms). This default is a project choice, not a crate default.

#### Scenario: Rapid file creation
- **WHEN** multiple files are created in quick succession within a project directory (e.g., git clone)
- **THEN** the scanner MUST batch these into a single project state update emitted after the debounce window

#### Scenario: Debounce configuration
- **WHEN** the user configures `debounce_ms = 5000` in the global config
- **THEN** the scanner MUST wait 5 seconds of filesystem quiet before emitting a batched update

## Litmus Tests

### Test: inotify backend detection on Linux
- **Setup**: Run scanner on Linux with inotify available
- **Action**: Create a new directory under watched path
- **Signal**: Directory appears in project state within debounce window
- **Pass**: Event received via inotify (not polling), zero CPU idle
- **Fail**: Event delayed beyond 3× debounce window, or CPU spikes during idle

### Test: FSEvents backend detection on macOS
- **Setup**: Run scanner on macOS with FSEvents available
- **Action**: Modify a file in a watched directory
- **Signal**: State change detected
- **Pass**: Event received via FSEvents, debounce-window accuracy maintained
- **Fail**: Fallback to polling or event loss

### Test: Watch limit exhaustion graceful degradation
- **Setup**: Fill inotify limit via concurrent watchers or many watch targets
- **Action**: Create new project directory when watch limit exceeded
- **Signal**: Scanner logs warning but continues
- **Pass**: Warning logged with clear guidance; existing watches remain active
- **Fail**: Scanner crashes or silently drops events

### Test: Debounce accumulation correctness
- **Setup**: Configure `debounce_ms = 500`
- **Action**: Create 10 files with 100ms spacing (total 1000ms > debounce)
- **Signal**: All files appear in single batched update
- **Pass**: One event emitted after 500ms silence, containing all 10 files
- **Fail**: Multiple events or individual events, or event after full 1000ms elapsed

### Test: Zero-CPU idle state
- **Setup**: Scanner running, no filesystem activity
- **Action**: Measure CPU usage for 10 seconds
- **Signal**: CPU usage remains near 0%
- **Pass**: Blocked on OS event wait (inotify, FSEvents, ReadDirectoryChangesW)
- **Fail**: Polling loop detected; CPU >1% sustained

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:filesystem-scanner" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

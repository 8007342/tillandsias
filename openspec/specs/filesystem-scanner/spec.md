<!-- @trace spec:filesystem-scanner -->
## Status

status: active

## MODIFIED Requirements

### Requirement: OS-native event-driven watching
The filesystem scanner SHALL use OS-native file event mechanisms (inotify on Linux, FSEvents on macOS, ReadDirectoryChangesW on Windows) via the `notify` crate's `RecommendedWatcher` and MUST NOT use polling loops of any kind.

#### Scenario: Project directory created on Linux
- **WHEN** a user creates a new directory under the watch path on Linux
- **THEN** the scanner detects the change via inotify and emits a project discovery event within the debounce window

#### Scenario: Project directory created on macOS
- **WHEN** a user creates a new directory under the watch path on macOS
- **THEN** the scanner detects the change via FSEvents (the default backend for `RecommendedWatcher` on macOS) and emits a project discovery event within the debounce window

#### Scenario: No changes occurring
- **WHEN** no filesystem changes have occurred
- **THEN** the scanner consumes zero CPU cycles (blocked on OS event wait)

#### Scenario: inotify watch limit exhausted on Linux
- **WHEN** the system's `fs.inotify.max_user_watches` limit is reached and the scanner cannot register new watches
- **THEN** the scanner logs a warning indicating the watch limit is exhausted and continues operating with existing watches. Depth-2 scanning minimizes the number of watches required, but systems with very low limits or many concurrent inotify consumers may still hit the cap.

### Requirement: Debounced event batching
The scanner SHALL debounce rapid filesystem events into batched project state updates with a configurable delay (project default: 2000ms). This default is a project choice, not a crate default.

#### Scenario: Rapid file creation
- **WHEN** multiple files are created in quick succession within a project directory (e.g., git clone)
- **THEN** the scanner batches these into a single project state update emitted after the debounce window

#### Scenario: Debounce configuration
- **WHEN** the user configures `debounce_ms = 5000` in the global config
- **THEN** the scanner waits 5 seconds of filesystem quiet before emitting a batched update

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:filesystem-scanner" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

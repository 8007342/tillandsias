# filesystem-scanner Specification

## Purpose
TBD - created by archiving change tillandsias-bootstrap. Update Purpose after archive.
## Requirements
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

### Requirement: Configurable watch path
The scanner SHALL watch `~/src` by default, with the watch path configurable via the global config file. Multiple watch paths SHALL be supported.

#### Scenario: Default watch path
- **WHEN** no watch path is configured
- **THEN** the scanner watches `~/src`

#### Scenario: Custom watch path
- **WHEN** the user configures `watch_paths = ["~/projects", "~/work"]` in the global config
- **THEN** the scanner watches both directories for project changes

### Requirement: Shallow depth scanning
The scanner SHALL watch at depth 2 from the watch path (project directory level) and MUST NOT recurse into project internals such as `node_modules`, `.git`, or `target` directories.

#### Scenario: Watch depth boundary
- **WHEN** a file changes inside `~/src/my-project/node_modules/`
- **THEN** the scanner does not emit an event for that change

#### Scenario: Project-level change
- **WHEN** a new directory `~/src/new-project/` is created
- **THEN** the scanner emits a project discovery event

### Requirement: Debounced event batching
The scanner SHALL debounce rapid filesystem events into batched project state updates with a configurable delay (project default: 2000ms). This default is a project choice, not a crate default.

#### Scenario: Rapid file creation
- **WHEN** multiple files are created in quick succession within a project directory (e.g., git clone)
- **THEN** the scanner batches these into a single project state update emitted after the debounce window

#### Scenario: Debounce configuration
- **WHEN** the user configures `debounce_ms = 5000` in the global config
- **THEN** the scanner waits 5 seconds of filesystem quiet before emitting a batched update

### Requirement: Project detection heuristics
The scanner SHALL detect all non-empty, non-hidden directories under the watch path as projects, regardless of whether they contain recognized manifest files.

#### Scenario: Directory with no manifest
- **WHEN** a non-empty directory exists in ~/src with no Cargo.toml, package.json, etc
- **THEN** it is detected as an Unknown-type project eligible for "Attach Here"

#### Scenario: Empty directory
- **WHEN** an empty directory exists in ~/src
- **THEN** it is still detected as a project (the user created it for a reason)

### Requirement: Low-priority background execution
The scanner SHALL run as a low-priority tokio task that MUST NOT block the main event loop or interfere with tray responsiveness.

#### Scenario: Heavy filesystem activity
- **WHEN** a large number of filesystem events occur simultaneously (e.g., mass file extraction)
- **THEN** the tray menu remains instantly responsive and scanner events are queued and processed without impacting UI


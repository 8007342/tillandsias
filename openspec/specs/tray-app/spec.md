# tray-app Specification

## Purpose

The Tillandsias tray application — a system tray icon that exposes a single
near-flat menu for launching projects, managing their forge containers, and
quitting cleanly. Wraps the headless enclave (proxy / git mirror / inference)
behind a five-stage state machine that keeps Quit and Language always
responsive even during long-running image builds and credential probes.
## Requirements
### Requirement: Cross-platform tray behavior
The tray application SHALL function correctly on Linux, macOS, and Windows using Tauri v2's native tray support.

#### Scenario: Linux tray
- **WHEN** the application runs on Linux
- **THEN** the tray icon integrates with the desktop environment via DBus StatusNotifierItem (libayatana-appindicator)

#### Scenario: macOS tray
- **WHEN** the application runs on macOS
- **THEN** the tray icon appears in the macOS menu bar as a native NSStatusItem

#### Scenario: Windows tray
- **WHEN** the application runs on Windows
- **THEN** the tray icon appears in the Windows system tray notification area

### Requirement: Seedlings submenu exposes OpenCode Web

The Seedlings submenu SHALL list three agent choices — "OpenCode Web", "OpenCode", and "Claude" — with "OpenCode Web" first and marked as the active choice when `AgentConfig::selected` is `OpenCodeWeb`.

#### Scenario: Default selection on fresh install
- **WHEN** the tray menu is built and no prior agent preference exists
- **THEN** "OpenCode Web" is rendered with the active-choice indicator
- **AND** clicking "OpenCode" or "Claude" updates the config and re-renders the menu with the new active choice

#### Scenario: Menu IDs remain stable
- **WHEN** the user picks "OpenCode Web" from the Seedlings submenu
- **THEN** the menu event carries the id `select-agent:opencode-web`
- **AND** `save_selected_agent()` persists `opencode-web` to `~/.config/tillandsias/config.toml`

### Requirement: Attach Here branches on selected agent

Clicking "Attach Here" SHALL dispatch to the web-session flow when `AgentConfig::selected` is `OpenCodeWeb`, and to the existing terminal flow otherwise.

#### Scenario: Web flow on default install
- **WHEN** `agent.selected = opencode-web` and the user clicks "Attach Here"
- **THEN** no terminal emulator is spawned
- **AND** a detached web container is started (if not already running)
- **AND** a `WebviewWindow` opens against the mapped host port

#### Scenario: Terminal flow preserved for opt-in users
- **WHEN** `agent.selected = opencode` or `claude` and the user clicks "Attach Here"
- **THEN** the existing terminal-based flow runs unchanged

### Requirement: Tray menu has a fixed five-stage state machine

The tray SHALL render exactly one of five menu states at any moment.
The state machine MUST be deterministic — given the (`enclave_health`,
`credential_health`, `remote_repo_fetch_status`) triple there is one
correct stage.

| Stage      | Trigger                                                          | Visible items |
|------------|------------------------------------------------------------------|---------------|
| `Booting`  | Tray just started; one or more enclave images still building     | contextual status line (`Building […]…`), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Ready`    | All enclave images ready; before the credential probe completes  | optional contextual status line (`<image> ready`, only within 2s flash window), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NoAuth`   | Credential probe returned `CredentialMissing` or `CredentialInvalid` | `🔑 Sign in to GitHub` (enabled action), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Authed`   | Credential probe returned `Authenticated` and remote-repo fetch succeeded (or local-only) | running-stack submenus (zero or more), `🏠 ~/src ▸` (only if non-empty), `☁️ Cloud ▸` (only if non-empty), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NetIssue` | Credential probe returned `GithubUnreachable` (or remote fetch failed transiently) | `🔑 Sign in to GitHub` (enabled action), contextual status line (`GitHub unreachable — using cached list`), running-stack submenus, `🏠 ~/src ▸` (only if non-empty), divider, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |

`Quit Tillandsias` SHALL appear in every stage and SHALL always be enabled. The single combined `v<version> — by Tlatoāni` line SHALL appear in every stage immediately above `Quit Tillandsias` and SHALL always be disabled (visual signature only). The `Language ▸` submenu SHALL NOT appear in any stage; the locale defaults to `en` until i18n is re-enabled in a future change. No other disabled item SHALL appear in any stage except the contextual status line described above.

#### Scenario: Version + signature persist across all stages
- **WHEN** the tray transitions between any two stages (e.g.,
  `Booting` → `Authed`)
- **THEN** the single combined signature row `v<version> — by Tlatoāni` SHALL remain visible immediately above `Quit Tillandsias`
- **AND** the signature row SHALL be disabled (no click handler)
- **AND** its text SHALL not change between stages

#### Scenario: Booting → Ready transition
- **WHEN** the last of the enclave images (forge / proxy / git /
  inference / router) reports ready
- **THEN** the menu transitions from `Booting` to `Ready`
- **AND** the contextual status line shows the transient `<image> ready` text for at most 2 seconds, then is removed
- **AND** the credential probe is kicked off in the background

#### Scenario: Ready → NoAuth transition
- **WHEN** the credential probe returns `CredentialMissing` or
  `CredentialInvalid`
- **THEN** any transient status line is removed and `🔑 Sign in to GitHub` is appended as an enabled action
- **AND** no `🏠 ~/src ▸` or `☁️ Cloud ▸` submenu is appended

#### Scenario: Ready → Authed transition
- **WHEN** the credential probe returns `Authenticated`
- **AND** the remote-repo fetch succeeds (or the user has chosen
  local-only)
- **THEN** any running-stack submenus are appended at the top
- **AND** `🏠 ~/src ▸` is appended if `state.projects` is non-empty
- **AND** `☁️ Cloud ▸` is appended if any remote repo is not yet cloned locally

#### Scenario: NetIssue offers cached projects
- **WHEN** the host has previously fetched a remote project list and
  the latest probe returned `GithubUnreachable`
- **THEN** `🏠 ~/src ▸` SHALL still populate from the on-disk cache
- **AND** the contextual status line SHALL include `GitHub unreachable — using cached list`
- **AND** the `🔑 Sign in to GitHub` action SHALL be present (enabled) so the user can retry

#### Scenario: Language submenu is hidden in all stages
- **WHEN** the menu is open in any of the five stages
- **THEN** the menu SHALL NOT contain a `Language ▸` submenu
- **AND** the static row at the bottom is exactly `[separator] [v<version> — by Tlatoāni] [Quit Tillandsias]`

### Requirement: Menu items are pre-built and toggled, never rebuilt on stage change

The tray SHALL pre-build every static menu item at `setup` time. Static items are: `Language ▸`, the combined `v<version> — by Tlatoāni` signature line, and `Quit Tillandsias`. Static items SHALL NOT be rebuilt across stage transitions; their handles are kept alive and only their `set_text` is called when the locale changes.

The variable region (contextual status line, sign-in action, running-stack submenus, `Projects ▸`, `Remote Projects ▸`) SHALL be appended and removed via `Menu::append` / `Menu::remove` based on the current `(stage, state)` projection. The variable region's update SHALL be guarded by a single cache key over `(running_stacks, local_projects, remote_projects, status_text, sign_in_visible)` — re-rendering happens only when the key changes.

#### Scenario: Stage flip does not flicker
- **WHEN** the menu transitions from `Booting` to `Authed`
- **THEN** the static row at the bottom (Language ▸, signature, Quit) is untouched
- **AND** the variable region is updated in a single batched pass — the user does not see the menu collapse or flash empty

#### Scenario: Variable-region refresh is debounced
- **WHEN** the scanner emits multiple project events within 100 ms
- **THEN** the variable region is updated at most once per debounce window
- **AND** the update is gated on the cache-key tuple `(running_stacks, local_projects, remote_projects, status_text, sign_in_visible)` not having changed

### Requirement: Tray Launch SHALL open opencode-web; CLI launch SHALL drop into a terminal

The tray SHALL spawn (or reuse) one forge container running
`opencode serve` + the SSE keepalive proxy when the user clicks
`🌱 Attach Here` on a project entry, and SHALL open a browser window pointing
at `http://<project>.opencode.localhost/`. The tray SHALL NOT offer
an agent picker.

The CLI runner SHALL drop into the forge's maintenance terminal
(`entrypoint-terminal.sh`) when invoked as `tillandsias <path>`
without `--opencode` / `--claude` overrides. CLI-level overrides
(`--opencode`, `--claude`, `--bash`) are preserved for power users.

#### Scenario: Tray Attach Here uses opencode-web, period
- **WHEN** the user clicks `Projects ▸ → my-project → 🌱 Attach Here`
- **THEN** the tray SHALL ensure the forge is running with
  `entrypoint-forge-opencode-web.sh`
- **AND** the tray SHALL open the user's native browser to the
  enclave URL
- **AND** the tray SHALL NOT prompt for which agent to use

#### Scenario: Attach Another reopens the same forge
- **WHEN** a forge for `my-project` is already running and the user
  clicks `🌱 Attach Another` under the top-level running-stack submenu
- **THEN** the tray SHALL NOT spawn a second container
- **AND** the tray SHALL just open another browser window pointing at
  the same URL — opencode-web supports multiple concurrent sessions

#### Scenario: Cold-start uses Attach Here, reattach uses Attach Another
- **WHEN** the user opens the tray menu for a project whose forge is NOT running
- **THEN** the project appears only under `Projects ▸`, with a `🌱 Attach Here` action
- **AND** clicking it dispatches `MenuCommand::Launch` and starts the forge
- **AND once** the forge is running, the same project additionally appears as a top-level running-stack submenu whose action is `🌱 Attach Another` (same `MenuCommand::Launch` dispatch, different label communicating that the forge is already up)

### Requirement: Maintenance terminal opens a shell in the running forge

The `🔧 Maintenance` action SHALL spawn a host terminal running
`podman exec -it tillandsias-<project>-forge /bin/bash` against the
running forge. Multiple maintenance terminals against the same forge
are allowed and each click spawns an additional independent terminal.
The `🔧 Maintenance` action SHALL appear only inside running-stack submenus and inside the per-project `Projects ▸ → <project> ▸` submenu when that project's forge is currently running. It SHALL NOT appear (not even disabled) when the project's forge is not running.

#### Scenario: Maintenance terminal attaches to the existing container
- **WHEN** the user clicks `my-project 🌺 ▸ → 🔧 Maintenance`
- **AND** the forge container `tillandsias-my-project-forge` is running
- **THEN** the host SHALL open a terminal emulator running
  `podman exec -it tillandsias-my-project-forge /bin/bash`
- **AND** the user lands in `/home/forge/src/my-project` with the full
  hard-installed toolkit on PATH

#### Scenario: Maintenance is hidden when forge is down
- **WHEN** no forge is running for `my-project`
- **THEN** the `Projects ▸ → my-project ▸` submenu SHALL NOT contain a `🔧 Maintenance` row (not even disabled)
- **AND** there SHALL be no top-level running-stack submenu for `my-project`

### Requirement: Quit always serviceable within 5 seconds

The tray SHALL guarantee `MenuCommand::Quit` transitions to
`shutdown_all()` within 5 seconds of the user click, regardless of
in-flight image builds, probes, or pulls. The event loop's
`tokio::select!` SHALL use `biased;` so Quit takes priority. Long-
running spawns SHALL hold a `CancellationToken` the Quit handler
aborts before entering shutdown.

#### Scenario: Quit during forge image build
- **WHEN** a forge image build is 30% complete and the user clicks Quit
- **THEN** the in-flight build task is aborted via its cancel token
- **AND** `shutdown_all` starts within 5 seconds
- **AND** the process exits within the usual `shutdown_all` budget

#### Scenario: Quit when nothing is in flight
- **WHEN** the tray is idle and the user clicks Quit
- **THEN** `shutdown_all` starts within 1 second
- **AND** exits within 5 seconds

### Requirement: Stale containers swept on startup before UI is interactive

Before the event loop opens for user input, the tray SHALL scan for
`tillandsias-*` containers and remove any whose `.State.StartedAt`
predates the current tray's PID start time. The enclave network is
also force-removed if it pre-exists. The sweep MUST run off the event
loop (so it doesn't block `MenuCommand::Quit`) but MUST complete before
any menu item capable of spawning a new container becomes enabled.

#### Scenario: Crash recovery on startup
- **WHEN** the tray starts and finds containers whose StartedAt
  predates this tray's PID start
- **THEN** every such container is `podman rm -f`'d
- **AND** the enclave network is `podman network rm -f`'d (if it
  pre-existed)
- **AND** `Projects ▸ → my-project → Launch` only becomes clickable
  after the sweep completes

### Requirement: Tray binds a host-local Unix control socket at startup

The tray application SHALL bind a Unix-domain stream socket
(`SOCK_STREAM`) at `$XDG_RUNTIME_DIR/tillandsias/control.sock` on Linux
when `XDG_RUNTIME_DIR` is set, and at `/tmp/tillandsias-$UID/control.sock`
otherwise. macOS uses the same template against `$TMPDIR`. The bind SHALL
occur before the tray icon becomes interactive, and the socket SHALL remain
open for the entire tray lifetime. On graceful shutdown the socket node
SHALL be unlinked from the filesystem.

The parent directory SHALL be created with mode `0700` if absent. The
socket node SHALL have mode `0600`, set in-place between `bind(2)` and
`listen(2)` so that no other-user `connect(2)` can race the default-mode
window.

@trace spec:tray-host-control-socket, spec:tray-app

#### Scenario: Socket created at startup with owner-only permissions

- **WHEN** the tray process starts and reaches the post-init phase
- **THEN** the file at `$XDG_RUNTIME_DIR/tillandsias/control.sock` exists
- **AND** the file is a Unix-domain socket node (per `stat(2)`)
- **AND** the file mode is exactly `0600`
- **AND** the parent directory mode is exactly `0700`
- **AND** the socket owner UID matches the tray process EUID

#### Scenario: XDG_RUNTIME_DIR fallback

- **WHEN** the tray starts in an environment where `XDG_RUNTIME_DIR` is
  unset or empty
- **THEN** the tray binds the socket at `/tmp/tillandsias-<euid>/control.sock`
- **AND** the parent directory `/tmp/tillandsias-<euid>/` is created with
  mode `0700`
- **AND** the socket file mode is `0600`
- **AND** an accountability log entry records the fallback at
  `category = "control-socket"`, `spec = "tray-host-control-socket"`

#### Scenario: Socket unlinked on graceful shutdown

- **WHEN** the tray exits via the Quit menu item or a SIGTERM
- **THEN** the listener task closes accepted streams cleanly
- **AND** the socket node at the bind path is `unlink(2)`-ed before the
  process exits
- **AND** an accountability log entry records the teardown

### Requirement: Stale-socket recovery on startup

When the bind path already exists at tray startup, the tray SHALL probe the
existing node before binding its own. The probe SHALL `connect(2)` with a
200 ms timeout; on success it SHALL exchange a `Hello`/`HelloAck` envelope
with a 500 ms total deadline. A live peer means another tray instance is
running and the new tray SHALL exit through the existing singleton-guard
path. A failed probe (connect error or deadline exceeded) means the node is
stale; the tray SHALL `unlink(2)` it and proceed with its own `bind(2)`.

@trace spec:tray-host-control-socket, spec:tray-app

#### Scenario: Stale socket from a crashed prior tray is recovered

- **WHEN** the tray starts and the bind path exists but no live tray owns it
- **AND** `connect(2)` to the path fails with `ECONNREFUSED` (or the probe
  deadline elapses with no response)
- **THEN** the tray unlinks the stale node
- **AND** binds its own socket at the same path
- **AND** logs the recovery at `category = "control-socket"`,
  `spec = "tray-host-control-socket"`, `operation = "stale-recovered"`

#### Scenario: Live peer at the bind path blocks startup

- **WHEN** the tray starts and the bind path exists and the probe receives a
  valid `HelloAck` envelope from the existing socket
- **THEN** the new tray does NOT unlink the socket
- **AND** the new tray exits via the singleton-guard path with the same
  user-visible message used for PID-based singleton conflicts
- **AND** an accountability log entry records the conflict

### Requirement: Postcard-framed wire format with versioned envelope

Every message on the control socket SHALL be encoded as a 4-byte big-endian
length prefix `N` followed by exactly `N` bytes of postcard-serialised
`ControlEnvelope`. The envelope SHALL carry a `wire_version: u16` (currently
`1`), a per-connection monotonic `seq: u64`, and a `body: ControlMessage`
typed enum. JSON SHALL NOT appear on the wire.

The envelope SHALL be opened with a `Hello` / `HelloAck` exchange before any
other variant is accepted; a `wire_version` mismatch between peers SHALL
close the connection with an `Error { code: Unsupported }` frame.

The `ControlMessage` enum SHALL be evolved additively: new variants append
at the end, existing variants SHALL NOT be reordered or deleted, and
deprecated variants SHALL be tombstoned per project convention rather than
removed.

@trace spec:tray-host-control-socket, spec:secrets-management

#### Scenario: Length-prefixed postcard envelope round-trips

- **WHEN** a consumer sends a `ControlMessage::Hello { from: "router",
  capabilities: vec!["IssueWebSession".to_string()] }` framed as a 4-byte
  big-endian length followed by the postcard bytes
- **THEN** the tray-side reader deserialises the envelope into the same
  variant with the same field values
- **AND** the tray replies with a `ControlMessage::HelloAck { wire_version:
  1, server_caps: <list> }` framed identically
- **AND** the connection proceeds to accept further frames

#### Scenario: Wire-version mismatch closes the connection

- **WHEN** a consumer sends a `Hello` envelope with `wire_version = 2` and
  the tray supports only `wire_version = 1`
- **THEN** the tray replies with a single `Error { code: Unsupported }`
  envelope at `wire_version = 1`
- **AND** the tray closes the stream after the error frame is flushed
- **AND** an accountability log entry records the version conflict at
  `category = "control-socket"`, `spec = "tray-host-control-socket"`

#### Scenario: Unknown enum variant is rejected at deserialise

- **WHEN** a consumer writes a postcard payload whose variant index is not
  in the tray's `ControlMessage` enum
- **THEN** the tray's deserialise step fails
- **AND** the tray replies with `Error { code: UnknownVariant,
  seq_in_reply_to: <seq if recoverable, else None> }`
- **AND** the offending bytes do NOT mutate any tray-side state
- **AND** an accountability warning records the rejection

#### Scenario: No JSON appears on the wire

- **WHEN** auditing the byte stream of every message the tray sends or
  accepts on the control socket
- **THEN** the framing matches `[u32 length BE][postcard bytes]` exactly
- **AND** no JSON object delimiters (`{`, `}`, `"`) appear at the framing
  layer
- **AND** the postcard payloads decode against the project's
  `ControlEnvelope` schema

### Requirement: Per-connection resource limits

The tray SHALL enforce the following limits on every accepted connection:

- Maximum single-message length: 64 KiB (`65536` bytes); a length prefix
  greater than this SHALL close the connection after sending
  `Error { code: PayloadTooLarge }`.
- Per-connection idle timeout: 60 seconds with no inbound bytes SHALL close
  the connection.
- Maximum concurrent accepted connections: 32; the `accept(2)` loop SHALL
  use a `tokio::sync::Semaphore` permit to backpressure new connections
  beyond the cap.

@trace spec:tray-host-control-socket, spec:tray-app

#### Scenario: Oversized frame closes the connection

- **WHEN** a consumer writes a 4-byte length prefix encoding a value
  greater than `65536`
- **THEN** the tray sends an `Error { code: PayloadTooLarge }` envelope
- **AND** closes the stream
- **AND** does not attempt to read or buffer the would-be payload bytes

#### Scenario: Idle connection times out

- **WHEN** an accepted connection sends no bytes for 60 seconds
- **THEN** the tray closes the stream
- **AND** logs the timeout at `category = "control-socket"`,
  `spec = "tray-host-control-socket"`, `operation = "idle-timeout"`

#### Scenario: Concurrent-connection cap backpressures

- **WHEN** 32 connections are already active and a 33rd consumer attempts
  `connect(2)`
- **THEN** the kernel `accept(2)` queue holds the connection until a
  semaphore permit is released
- **AND** the tray does not OOM, panic, or refuse subsequent legitimate
  connections after a permit frees

### Requirement: Bind-mount of control socket into consumer containers

The tray SHALL include the control socket as a read-write bind mount in
every container it launches that is declared (in its container profile) as
a control-socket consumer. The mount target inside the container SHALL be
`/run/host/tillandsias/control.sock`. The launch context SHALL set the
environment variable `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
inside the container so client libraries can read a single canonical path.

The bind mount SHALL be added without relaxing any existing security flag —
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`,
and `--rm` SHALL remain in effect for the consumer container.

@trace spec:tray-host-control-socket, spec:podman-orchestration

#### Scenario: Router container receives the bind mount

- **WHEN** the tray launches the router container
- **THEN** the podman command line contains
  `-v <host-socket-path>:/run/host/tillandsias/control.sock`
- **AND** the environment carries
  `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
- **AND** `--cap-drop=ALL` and `--security-opt=no-new-privileges` remain
  on the command line

#### Scenario: Forge container without consumer profile gets no mount

- **WHEN** the tray launches a forge container whose profile does NOT
  declare it as a control-socket consumer
- **THEN** the podman command line does NOT contain the control-socket
  bind mount
- **AND** the `TILLANDSIAS_CONTROL_SOCKET` environment variable is not set

### Requirement: Consumer reconnect after tray restart

Consumer containers SHALL implement reconnect with exponential backoff when
the control socket disconnects. The backoff SHALL start at 100 ms and
double on each failure, capped at 5 seconds, retrying indefinitely. After
each successful reconnect the consumer SHALL re-send `Hello` and re-issue
any session-scoped state required by its capability before resuming
normal operation.

@trace spec:tray-host-control-socket

#### Scenario: Consumer survives tray restart

- **WHEN** the tray exits while a router consumer holds an open control
  connection
- **AND** the tray restarts within 30 seconds
- **THEN** the consumer's reconnect loop establishes a new connection
- **AND** the consumer sends `Hello` on the new connection
- **AND** subsequent `IssueWebSession` envelopes succeed without operator
  intervention

#### Scenario: Backoff caps at five seconds

- **WHEN** a consumer attempts reconnect and the tray remains absent for
  more than 60 seconds
- **THEN** the backoff between attempts grows monotonically until reaching
  5 seconds, then stays at 5 seconds for all subsequent attempts
- **AND** the reconnect loop continues indefinitely (no abort) until the
  tray returns or the consumer container is stopped

### Requirement: Status chip is additive across subsystem completions

The tray menu's status chip SHALL be a single line whose emoji prefix accumulates as each infrastructure subsystem comes online. Concretely:

1. The line begins with the constant ASCII emoji `✅` (white-heavy-check).
2. After `✅`, an emoji per completed subsystem appears in stable, deterministic order:
   - `🧭` (compass) — browser runtime
   - `🕸️` (spider web) — enclave network
   - `🛡️` (shield) — proxy
   - `🧠` (brain) — inference
   - `🔀` (shuffle) — router
   - `🪞` (mirror) — git mirror
   - `🔨` (hammer) — forge image
3. The tail of the line is the current action text:
   - While a build is in progress: `Building <subsystem-friendly-name> …`
   - For 2 seconds after a build completes: `<subsystem-friendly-name> OK`
4. On `Stage::NetIssue`, ` · GitHub unreachable — using cached list` is appended to the tail.

A subsystem's emoji appears once per build. Re-builds of the same subsystem (e.g., proxy crashed and was restarted) do NOT add a duplicate emoji to the prefix; the dedup is by sort order.

#### Scenario: Cold start chip — verifying baseline
- **WHEN** the tray launches AND no build has completed AND no build is in progress AND `Stage::Booting`
- **THEN** the chip text SHALL be `✅ Verifying environment …` (the localized value of `menu.status.verifying_environment`)

#### Scenario: First completion adds emoji + flash
- **WHEN** the browser runtime build completes AND no other build is in progress
- **THEN** the chip text SHALL be `✅🧭 Browser runtime OK` for 2 seconds
- **AND** after 2 seconds the chip SHALL be removed from the menu (no in-progress, no flash window)

#### Scenario: Multiple completions accumulate
- **WHEN** browser runtime + enclave + proxy have all completed AND inference is currently building
- **THEN** the chip text SHALL be `✅🧭🕸️🛡️ Building Inference Engine …`
- **AND** the emojis SHALL appear in the deterministic order above (compass → web → shield), regardless of completion timing

#### Scenario: NetIssue suffix joins same chip line
- **WHEN** `Stage::NetIssue` AND browser + enclave + proxy completed AND no in-progress builds AND a recent completion is within the 2 s flash window
- **THEN** the chip SHALL contain both the per-subsystem emoji prefix AND the GitHub-unreachable suffix on a single line, separated by ` · `

### Requirement: Unhealthy stage collapses menu to single status item

When `current_stage` detects a failed build with no concurrent retry in flight, it SHALL return `Stage::Unhealthy`. The menu's dynamic region SHALL collapse to a single disabled item with the localized value of `menu.unhealthy_environment` (default English: `🥀 Unhealthy environment`). The sign-in action, running-stack submenus, `🏠 ~/src ▸`, and `☁️ Cloud ▸` SHALL all be hidden in this stage.

Detail of which specific subsystem failed lives in the accountability log, NOT in the menu. The menu's job is signalling severity ("something is wrong, look at the logs"), not enumerating failures.

#### Scenario: Failed forge build → Unhealthy
- **WHEN** the forge image build returns `BuildProgressEvent::Failed` AND no retry has fired yet
- **THEN** `current_stage` SHALL return `Stage::Unhealthy`
- **AND** the menu's dynamic region SHALL contain only `🥀 Unhealthy environment`
- **AND** the static row at the bottom SHALL still contain `[separator] [signature] [Quit Tillandsias]`

#### Scenario: Retry supersedes Unhealthy
- **WHEN** an Unhealthy state transitions to a fresh `BuildProgressEvent::Started` for the same image
- **THEN** the prior `Failed` row in `state.active_builds` SHALL be cleared (per existing `event_loop.rs::handle_build_progress_event::Started` behaviour)
- **AND** `current_stage` SHALL return `Stage::Booting`
- **AND** the chip SHALL re-appear with the prior emoji prefix preserved (completed subsystems are NOT lost on Unhealthy → Booting transitions)

### Requirement: Sign-in label uses "GitHub Login" wording

The localized value of `menu.sign_in_github` SHALL be `🔑 GitHub Login` (en) / `🔑 GitHub-Anmeldung` (de) / `🔑 Iniciar sesión en GitHub` (es). The change is wording-only — the menu item ID (`tm.sign-in`) and dispatch (`MenuCommand::GitHubLogin`) are unchanged.

#### Scenario: NoAuth shows the new wording
- **WHEN** `Stage::NoAuth` AND the menu is open
- **THEN** the menu item with id `tm.sign-in` SHALL render the text `🔑 GitHub Login` (in the active locale)

### Requirement: Tray menu forbids disabled placeholder items

The tray menu SHALL NOT contain disabled items whose only purpose is to communicate "nothing to show here" or "this is unavailable right now". The only permitted disabled item is the single signature line (see *Signature collapses to one line* below). Status indicators MAY be disabled but only when actively conveying a current condition; idle status placeholders are forbidden.

#### Scenario: Empty Projects submenu is hidden, not stubbed
- **WHEN** the user has signed in but no local projects exist under any watched path
- **THEN** the `Projects ▸` submenu SHALL NOT appear in the tray menu at all
- **AND** no `No local projects` placeholder row SHALL be rendered anywhere

#### Scenario: Empty Remote Projects submenu is hidden, not stubbed
- **WHEN** the user has signed in and the remote repo fetch returned a list whose entries are all already cloned locally
- **THEN** the `Remote Projects ▸` submenu SHALL NOT appear in the tray menu
- **AND** no `No remote projects` placeholder row SHALL be rendered anywhere

#### Scenario: Idle Booting/Ready states show no chip
- **WHEN** no enclave image is currently building AND no recent build has completed within the 2-second `Ready` flash window
- **THEN** no disabled `Building […]` or `Ready` row SHALL be present in the menu

### Requirement: Signature collapses to one line

The version and attribution SHALL be rendered as a single disabled menu item with the text `v<full-version> — by Tlatoāni` (e.g., `v0.1.169.225 — by Tlatoāni`). This item SHALL appear immediately above `Quit Tillandsias` in every stage and SHALL never change position or text between stages.

#### Scenario: One signature line, not two
- **WHEN** the tray menu is open in any stage
- **THEN** there SHALL be exactly one disabled signature row of the form `v<version> — by Tlatoāni`
- **AND** there SHALL NOT be a separate disabled `v<version>` row above a separate disabled `— by Tlatoāni` row

#### Scenario: Signature persists across stage transitions
- **WHEN** the tray transitions between any two stages (e.g., `Booting` → `Authed`)
- **THEN** the signature row's text and position SHALL remain unchanged
- **AND** it SHALL remain immediately above `Quit Tillandsias`

### Requirement: Contextual status line is shown only when a relevant condition holds

The tray menu MAY display at most ONE optional contextual status line at the top of the menu. The status line SHALL be appended only when at least one of these conditions holds: a forge image build is in progress, an enclave-step image build is in progress, a build has completed within the last 2 seconds (transient `Ready` window), or the credential probe returned `GithubUnreachable`. When none of these conditions hold, the status line SHALL be absent from the menu (not present-and-disabled).

#### Scenario: No status line when idle and authed
- **WHEN** all enclave images are ready AND credentials are healthy AND no build has completed within the last 2 seconds
- **THEN** the menu SHALL NOT contain any status row above the running stacks / Projects submenus

#### Scenario: Building forge surfaces a status line
- **WHEN** a forge image build is in progress
- **THEN** the menu SHALL contain a single disabled status row whose text identifies the build (e.g., `Building forge…`)
- **AND** the row SHALL be removed from the menu when the build completes the 2-second `Ready` flash window

#### Scenario: Multiple concurrent conditions collapse to one row
- **WHEN** an enclave-step build is in progress AND credentials are `GithubUnreachable`
- **THEN** the menu SHALL contain exactly one status row whose text reflects all active conditions (joined with a separator), not one row per condition

### Requirement: Sign-in is rendered as an enabled action, not a disabled banner

When the credential probe reports `CredentialMissing`, `CredentialInvalid`, or `GithubUnreachable`, the tray menu SHALL contain an enabled `🔑 Sign in to GitHub` action that dispatches `MenuCommand::GitHubLogin` on click. When credentials are healthy, the sign-in action SHALL NOT appear in the menu — neither enabled nor disabled.

#### Scenario: Authed state hides sign-in entirely
- **WHEN** the credential probe returns `Authenticated`
- **THEN** the menu SHALL NOT contain a `Sign in to GitHub` row in any state

#### Scenario: NoAuth state shows sign-in as enabled
- **WHEN** the credential probe returns `CredentialMissing` or `CredentialInvalid`
- **THEN** the menu SHALL contain an enabled `🔑 Sign in to GitHub` row that dispatches `MenuCommand::GitHubLogin` on click

#### Scenario: NetIssue state shows both sign-in and the contextual status line
- **WHEN** the credential probe returns `GithubUnreachable`
- **THEN** the menu SHALL contain an enabled `🔑 Sign in to GitHub` row
- **AND** the contextual status line SHALL include `GitHub unreachable` text

### Requirement: Projects and Remote Projects render as sibling top-level submenus

When the credential probe is `Authenticated` (or `NetIssue` with cached projects available), local and remote projects SHALL render as two sibling top-level submenus. Their labels SHALL be `🏠 ~/src ▸` (local watch-path projects) and `☁️ Cloud ▸` (uncloned GitHub repos). The labels MUST carry the emoji prefix so users can visually distinguish "what's on disk" from "what's in the cloud" at a glance.

Each submenu is appended to the menu only when it would have at least one entry — empty submenus SHALL NOT appear.

The previous `Include remote` `CheckMenuItem` inside `Projects ▸` SHALL NOT exist. Its event variant `MenuCommand::IncludeRemoteToggle` SHALL be removed.

#### Scenario: Both submenus appear when both have entries
- **WHEN** `state.projects` is non-empty AND `state.remote_repos` contains at least one repo not present locally
- **THEN** the menu SHALL contain `🏠 ~/src ▸` and `☁️ Cloud ▸` as sibling top-level submenus
- **AND** clicking inside either submenu SHALL NOT cause the other to rebuild or flicker

#### Scenario: Only local submenu appears when no uncloned remotes
- **WHEN** `state.projects` is non-empty AND every repo in `state.remote_repos` is already cloned locally
- **THEN** the menu SHALL contain `🏠 ~/src ▸`
- **AND** the menu SHALL NOT contain `☁️ Cloud ▸` (not even as a disabled or empty row)

#### Scenario: Only cloud submenu appears when no local projects
- **WHEN** `state.projects` is empty AND `state.remote_repos` contains at least one repo
- **THEN** the menu SHALL contain `☁️ Cloud ▸`
- **AND** the menu SHALL NOT contain `🏠 ~/src ▸` (not even as a disabled or empty row)

#### Scenario: Clicking a cloud project clones and launches
- **WHEN** the user clicks a repo under `☁️ Cloud ▸ → <repo-name>`
- **THEN** the tray dispatches `MenuCommand::CloneProject { full_name, name }`
- **AND** the existing `handle_clone_project` flow runs — clone into the watch path, pre-insert the project into `state.projects`, then call `handle_attach_here` to launch the forge
- **AND** the project subsequently appears under `🏠 ~/src ▸` (no longer in `☁️ Cloud ▸`)

### Requirement: Running per-project stacks render as top-level submenus

For each project that has at least one container in `TrayState::running` of type `Forge`, `OpenCodeWeb`, or `Maintenance`, the tray menu SHALL render a top-level submenu above `Projects ▸` and `Remote Projects ▸`. The submenu label SHALL be `<project> <bloom> [<tool emojis>]` — the project name first, then the bloom emoji (when an `OpenCodeWeb` container is running for the project), then up to five tool emojis (one per running `Maintenance` container, in the order those containers entered `state.running`). When more than five `Maintenance` containers are running for one project, only the first five emojis SHALL appear in the label; no overflow indicator is rendered. The submenu SHALL contain exactly two children:

- `🌱 Attach Another` — dispatches `MenuCommand::Launch { project_path }`. The handler reattaches to the existing forge and opens an additional browser window. Multiple concurrent windows are permitted. The label is `Attach Another` (not `Attach Here`) to communicate that the forge is already up and clicking will spawn a sibling browser window, not start a fresh stack.
- `🔧 Maintenance` — dispatches `MenuCommand::MaintenanceTerminal { project_path }`. The handler `podman exec`s a fresh shell into the running forge container. Multiple concurrent shells are permitted.

The submenu SHALL NOT contain a Stop item. The only way to tear down a running stack is `Quit Tillandsias`, which `shutdown_all` already handles.

#### Scenario: Running project surfaces at the top
- **WHEN** the forge for `my-project` is running with an `OpenCodeWeb` container
- **THEN** a top-level submenu labeled `my-project 🌺 ▸` SHALL appear above `Projects ▸`
- **AND** the submenu SHALL contain `🌱 Attach Another` and `🔧 Maintenance` as its only two items

#### Scenario: Tool emojis appear after the bloom
- **WHEN** the forge for `my-project` is running AND one or more `Maintenance` containers for `my-project` are running
- **THEN** the top-level submenu label SHALL be of the form `my-project 🌺 🔧🪛 ▸` — name first, bloom second, tool emojis after
- **AND** the submenu's children SHALL still be exactly `🌱 Attach Another` and `🔧 Maintenance`

#### Scenario: Tool emoji count is capped at five
- **WHEN** six or more `Maintenance` containers are running for `my-project`
- **THEN** the top-level submenu label SHALL include exactly five tool emojis after the bloom — the emojis from the first five `Maintenance` containers in `state.running` order
- **AND** no overflow count or `+N` suffix SHALL appear in the label

#### Scenario: Attach Another opens an additional browser window
- **WHEN** the user clicks `my-project 🌺 ▸ → 🌱 Attach Another` on a project whose forge is already running
- **THEN** `handle_attach_web` SHALL take the reattach branch and open a second native-browser window pointed at the same forge URL
- **AND** no new container SHALL be spawned

#### Scenario: Maintenance allows concurrent shells
- **WHEN** the user clicks `my-project 🌺 ▸ → 🔧 Maintenance` twice in succession
- **THEN** two independent terminal emulators SHALL open, each with a fresh `podman exec` into the same forge container

#### Scenario: Only Quit closes a running stack
- **WHEN** any running stacks are present in the menu
- **THEN** the menu SHALL NOT contain any per-stack Stop or Close action
- **AND** the only menu interaction that tears down running stacks SHALL be `Quit Tillandsias`, which invokes `handlers::shutdown_all`

### Requirement: Locale defaults to en until i18n is re-enabled

The `i18n::initialize` (or equivalent locale-selection function) SHALL hard-code the active locale to `"en"` regardless of `LANG`, `LC_ALL`, OS settings, or saved user preference. The locale-loading pipeline (embedded `.toml` files, `i18n::t` / `i18n::tf` lookups, `STRINGS` table) SHALL remain functional so a one-line change in `initialize` re-enables locale selection later. The `MenuCommand::SelectLanguage` event variant SHALL remain in the enum (the dispatch path stays valid; only the menu item that emits it is removed).

#### Scenario: Locale is en regardless of OS settings
- **WHEN** the tray starts on a host with `LANG=fr_FR.UTF-8`
- **THEN** `i18n::current_language()` returns `"en"`
- **AND** `i18n::t("menu.quit")` returns the English value `"Quit Tillandsias"`

#### Scenario: i18n pipeline still functional
- **WHEN** code calls `i18n::tf("menu.signature_with_version", &[("version", "0.1.169.227")])`
- **THEN** the result is a non-empty string with the version interpolated
- **AND** the call does not panic or return an error

#### Scenario: Re-enabling is a one-line change
- **WHEN** a future contributor wants to bring the Language submenu back
- **THEN** they SHALL only need to (a) revert the `initialize` hard-code to call the OS-detection helper that is preserved as a tombstoned function, and (b) un-tombstone the `.item(&self.language)` line in `apply_state`
- **AND** no other code change is required to restore the previous behaviour


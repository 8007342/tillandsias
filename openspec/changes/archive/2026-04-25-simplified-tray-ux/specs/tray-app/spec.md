## ADDED Requirements

### Requirement: Tray menu has a fixed five-stage state machine

The tray SHALL render exactly one of five menu states at any moment.
The state machine MUST be deterministic — given the (`enclave_health`,
`credential_health`, `remote_repo_fetch_status`) triple there is one
correct stage.

| Stage      | Trigger                                                          | Visible items |
|------------|------------------------------------------------------------------|---------------|
| `Booting`  | Tray just started; one or more enclave images still building     | `Building [...]` (label updates per image), divider, `Language ▸`, version (disabled), `— by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Ready`    | All enclave images ready; before the credential probe completes  | `Ready` (transient ≤2s), divider, `Language ▸`, version (disabled), `— by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NoAuth`   | Credential probe returned `CredentialMissing` or `CredentialInvalid` | `Sign in to GitHub`, divider, `Language ▸`, version (disabled), `— by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Authed`   | Credential probe returned `Authenticated` and remote-repo fetch succeeded (or local-only) | `Projects ▸`, divider, `Language ▸`, version (disabled), `— by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NetIssue` | Credential probe returned `GithubUnreachable` (or remote fetch failed transiently) | `Sign in to GitHub`, `(GitHub unreachable, using cached projects)`, `Projects ▸`, `Language ▸`, version (disabled), `— by Tlatoāni` (disabled), `Quit Tillandsias` |

`Language ▸` and `Quit Tillandsias` SHALL appear in every stage and SHALL
always be enabled. The version and `— by Tlatoāni` lines SHALL appear in
every stage immediately above `Quit Tillandsias` and SHALL always be
disabled (visual signature only — clicking does nothing).

#### Scenario: Version + signature persist across all stages
- **WHEN** the tray transitions between any two stages (e.g.,
  `Booting` → `Authed`)
- **THEN** the version line (e.g., `v0.1.168.224`) SHALL remain visible
  immediately above `— by Tlatoāni`
- **AND** `— by Tlatoāni` SHALL remain visible immediately above
  `Quit Tillandsias`
- **AND** both lines SHALL be disabled (no click handler)
- **AND** their text SHALL not change between stages

#### Scenario: Booting → Ready transition
- **WHEN** the last of the four enclave images (forge / proxy / git /
  inference) reports ready
- **THEN** the menu transitions from `Booting` to `Ready`
- **AND** the `Building [...]` item is replaced (via item swap, not
  full menu rebuild) by `Ready`
- **AND** the credential probe is kicked off in the background

#### Scenario: Ready → NoAuth transition
- **WHEN** the credential probe returns `CredentialMissing` or
  `CredentialInvalid`
- **THEN** the `Ready` item is hidden and `Sign in to GitHub` becomes
  visible
- **AND** the `Projects ▸` submenu is hidden (set_visible(false))

#### Scenario: Ready → Authed transition
- **WHEN** the credential probe returns `Authenticated`
- **AND** the remote-repo fetch succeeds (or the user has chosen
  local-only)
- **THEN** `Projects ▸` becomes the primary action

#### Scenario: NetIssue offers cached projects
- **WHEN** the host has previously fetched a remote project list and
  the latest probe returned `GithubUnreachable`
- **THEN** `Projects ▸` SHALL still populate from the on-disk cache
- **AND** a sibling banner item `(GitHub unreachable, using cached
  projects)` is visible

### Requirement: Menu items are pre-built and toggled, never rebuilt on stage change

The tray SHALL pre-build every static menu item at `setup` time and
SHALL transition between stages by calling `set_enabled(bool)` and
swapping label text on the same item handles. Tauri 2 does not expose
`set_visible` for native menus on every platform; the tray
SHALL emulate hide-by-disable + label-update for stage-internal
toggling.

The Projects submenu MAY be rebuilt because its content (project
list) genuinely changes; it MUST NOT be rebuilt on every stage tick —
only when the project set or the `Include remote` toggle changes.

#### Scenario: Stage flip does not flicker
- **WHEN** the menu transitions from `Booting` to `Authed`
- **THEN** the user sees the items update in place
- **AND** the menu does not collapse or flash empty between states
- **AND** `rebuild_menu()` is NOT called for the static portion

#### Scenario: Project list refresh is debounced
- **WHEN** the scanner emits multiple project events within 100ms
- **THEN** the menu is rebuilt at most once per debounce window
- **AND** the rebuild is gated on `(local_set, remote_set,
  include_remote) != previous_tuple`

### Requirement: Tray Launch SHALL open opencode-web; CLI launch SHALL drop into a terminal

The tray SHALL spawn (or reuse) one forge container running
`opencode serve` + the SSE keepalive proxy when the user clicks
`Launch` on a project entry, and SHALL open a browser window pointing
at `http://<project>.opencode.localhost/`. The tray SHALL NOT offer
an agent picker.

The CLI runner SHALL drop into the forge's maintenance terminal
(`entrypoint-terminal.sh`) when invoked as `tillandsias <path>`
without `--opencode` / `--claude` overrides. CLI-level overrides
(`--opencode`, `--claude`, `--bash`) are preserved for power users.

#### Scenario: Tray Launch uses opencode-web, period
- **WHEN** the user clicks `Projects ▸ → my-project → Launch`
- **THEN** the tray SHALL ensure the forge is running with
  `entrypoint-forge-opencode-web.sh`
- **AND** the tray SHALL open the user's native browser to the
  enclave URL
- **AND** the tray SHALL NOT prompt for which agent to use

#### Scenario: Re-launch reopens the same forge
- **WHEN** a forge for `my-project` is already running and the user
  clicks `Launch` again
- **THEN** the tray SHALL NOT spawn a second container
- **AND** the tray SHALL just open another browser window pointing at
  the same URL — opencode-web supports multiple concurrent sessions

### Requirement: Maintenance terminal opens a shell in the running forge

The `Maintenance terminal` action SHALL spawn a host terminal running
`podman exec -it tillandsias-<project>-<genus> /bin/bash` against the
running forge. Multiple maintenance terminals against the same forge
are allowed. If the forge isn't running, the terminal action SHALL be
disabled until the user clicks `Launch`.

#### Scenario: Maintenance terminal attaches to the existing container
- **WHEN** the user clicks `Projects ▸ → my-project → Maintenance terminal`
- **AND** the forge container `tillandsias-my-project-<genus>` is
  running
- **THEN** the host SHALL open a terminal emulator running
  `podman exec -it tillandsias-my-project-<genus> /bin/bash`
- **AND** the user lands in `/home/forge/src/my-project` with the full
  hard-installed toolkit (java, mvn, gradle, python, rust, go, flutter,
  etc.) on PATH

#### Scenario: Maintenance terminal is disabled when forge is down
- **WHEN** no forge is running for `my-project`
- **THEN** the `Maintenance terminal` item is disabled
- **AND** clicking it has no effect (or surfaces a "click Launch first"
  hint via tooltip on platforms that support tray tooltips)

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

## ADDED Requirements

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

When the credential probe is `Authenticated` (or `NetIssue` with cached projects available), local and remote projects SHALL render as two sibling top-level submenus, `Projects ▸` and `Remote Projects ▸`. Each submenu is appended to the menu only when it would have at least one entry — empty submenus SHALL NOT appear.

The previous `Include remote` `CheckMenuItem` inside `Projects ▸` SHALL NOT exist. Its event variant `MenuCommand::IncludeRemoteToggle` SHALL be removed.

#### Scenario: Both submenus appear when both have entries
- **WHEN** `state.projects` is non-empty AND `state.remote_repos` contains at least one repo not present locally
- **THEN** the menu SHALL contain `Projects ▸` and `Remote Projects ▸` as sibling top-level submenus
- **AND** clicking inside either submenu SHALL NOT cause the other to rebuild or flicker

#### Scenario: Only Projects appears when no uncloned remotes
- **WHEN** `state.projects` is non-empty AND every repo in `state.remote_repos` is already cloned locally
- **THEN** the menu SHALL contain `Projects ▸`
- **AND** the menu SHALL NOT contain `Remote Projects ▸` (not even as a disabled or empty row)

#### Scenario: Only Remote Projects appears when no local projects
- **WHEN** `state.projects` is empty AND `state.remote_repos` contains at least one repo
- **THEN** the menu SHALL contain `Remote Projects ▸`
- **AND** the menu SHALL NOT contain `Projects ▸` (not even as a disabled or empty row)

#### Scenario: Clicking a remote project clones and launches
- **WHEN** the user clicks a repo under `Remote Projects ▸ → <repo-name>`
- **THEN** the tray dispatches `MenuCommand::CloneProject { full_name, name }`
- **AND** the existing `handle_clone_project` flow runs — clone into the watch path, pre-insert the project into `state.projects`, then call `handle_attach_here` to launch the forge

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

## MODIFIED Requirements

### Requirement: Tray menu has a fixed five-stage state machine

The tray SHALL render exactly one of five menu states at any moment.
The state machine MUST be deterministic — given the (`enclave_health`,
`credential_health`, `remote_repo_fetch_status`) triple there is one
correct stage.

| Stage      | Trigger                                                          | Visible items |
|------------|------------------------------------------------------------------|---------------|
| `Booting`  | Tray just started; one or more enclave images still building     | contextual status line (`Building […]…`), divider, `Language ▸`, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Ready`    | All enclave images ready; before the credential probe completes  | optional contextual status line (`<image> ready`, only within 2s flash window), divider, `Language ▸`, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NoAuth`   | Credential probe returned `CredentialMissing` or `CredentialInvalid` | `🔑 Sign in to GitHub` (enabled action), divider, `Language ▸`, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `Authed`   | Credential probe returned `Authenticated` and remote-repo fetch succeeded (or local-only) | running-stack submenus (zero or more), `Projects ▸` (only if non-empty), `Remote Projects ▸` (only if non-empty), divider, `Language ▸`, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |
| `NetIssue` | Credential probe returned `GithubUnreachable` (or remote fetch failed transiently) | `🔑 Sign in to GitHub` (enabled action), contextual status line (`GitHub unreachable — using cached list`), running-stack submenus, `Projects ▸` (only if non-empty), divider, `Language ▸`, `v<version> — by Tlatoāni` (disabled), `Quit Tillandsias` |

`Language ▸` and `Quit Tillandsias` SHALL appear in every stage and SHALL
always be enabled. The single combined `v<version> — by Tlatoāni` line SHALL appear in every stage immediately above `Quit Tillandsias` and SHALL always be disabled (visual signature only — clicking does nothing). No other disabled item SHALL appear in any stage except the contextual status line described above, which SHALL appear only when a relevant condition holds.

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
- **AND** no `Projects ▸` or `Remote Projects ▸` submenu is appended

#### Scenario: Ready → Authed transition
- **WHEN** the credential probe returns `Authenticated`
- **AND** the remote-repo fetch succeeds (or the user has chosen
  local-only)
- **THEN** any running-stack submenus are appended at the top
- **AND** `Projects ▸` is appended if `state.projects` is non-empty
- **AND** `Remote Projects ▸` is appended if any remote repo is not yet cloned locally

#### Scenario: NetIssue offers cached projects
- **WHEN** the host has previously fetched a remote project list and
  the latest probe returned `GithubUnreachable`
- **THEN** `Projects ▸` SHALL still populate from the on-disk cache
- **AND** the contextual status line SHALL include `GitHub unreachable — using cached list`
- **AND** the `🔑 Sign in to GitHub` action SHALL be present (enabled) so the user can retry

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

## REMOVED Requirements

### Requirement: Per-project Stop action for running web containers
**Reason**: Per-project stop is removed. The user explicitly chose a "running stacks live until Quit" model — partial teardown is no longer offered. Stack lifetime is bound to app lifetime; `handlers::shutdown_all` cleans everything on `MenuCommand::Quit`.
**Migration**: Users who want to stop a single project's stack should `Quit Tillandsias` and reopen it. The `MenuCommand::Stop` event variant and the `Stop` menu item SHALL be removed from the tray menu.

### Requirement: First-launch readiness feedback
**Reason**: Replaced by the new contextual status line requirement. The "Setting up..." build chip becomes the contextual status line text when a forge build is in progress; the disabled forge-dependent items become hidden items (running-stack and per-project submenus only appear when the forge is up). The desktop-notification path on infrastructure failure is preserved by the existing handler code and is not part of the menu spec.
**Migration**: Replaced by *Contextual status line is shown only when a relevant condition holds* and *Running per-project stacks render as top-level submenus*. No additional code migration: the `forge_available` guard inside `handle_attach_web` and `handle_attach_here` continues to prevent attach attempts before the forge is ready.

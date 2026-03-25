## NEW Requirements

### Requirement: Open window registry
The application SHALL maintain a registry of all open terminal windows in `TrayState`, keyed by window label, for the duration of each window's lifetime.

#### Scenario: Window registered on creation
- **WHEN** a new Tauri terminal window is created (AttachHere or Maintenance)
- **THEN** an entry is added to `open_windows` with the window label, project path, genus (if applicable), window type, and creation timestamp

#### Scenario: Window removed on destruction
- **WHEN** `WindowEvent::Destroyed` fires for a tracked window label
- **THEN** the entry is removed from `open_windows`, the genus is released (if present), the project is removed from the running container set, and the tray menu is rebuilt

#### Scenario: Non-tracked window destroyed
- **WHEN** `WindowEvent::Destroyed` fires for a label that is not in `open_windows`
- **THEN** no state change occurs and no error is raised

---

### Requirement: Focus recovery for AttachHere
When the user clicks "Attach Here" for a project that already has an open terminal window, the application SHALL bring the existing window to the front instead of creating a new one.

#### Scenario: Window exists and is visible
- **WHEN** the user clicks "Attach Here" AND a window with the matching label exists
- **THEN** `set_focus()` is called on the existing window; no new window is created and no new container is started

#### Scenario: Window exists and is minimized
- **WHEN** the user clicks "Attach Here" AND the matching window is minimized
- **THEN** `unminimize()` is called before `set_focus()`; the window is restored and brought to the front

#### Scenario: No window exists
- **WHEN** the user clicks "Attach Here" AND no window with the matching label exists
- **THEN** the normal launch sequence proceeds: genus allocated, container started, PTY spawned, Tauri window created

---

### Requirement: Focus recovery for Maintenance terminal
The same focus recovery behavior SHALL apply to Maintenance terminal windows.

#### Scenario: Maintenance window exists
- **WHEN** the user clicks "Maintenance" for a project AND a window with label `tillandsias-<slug>-maintenance` exists
- **THEN** the existing maintenance window is focused (and unminimized if needed); no new window or container is created

#### Scenario: No maintenance window exists
- **WHEN** the user clicks "Maintenance" AND no maintenance window is open
- **THEN** the normal maintenance launch sequence proceeds

---

### Requirement: Terminal death triggers cleanup
When a terminal session ends (container exits or PTY receives EOF), the associated Tauri window SHALL close and full cleanup SHALL occur.

#### Scenario: Container exits normally (user types "exit")
- **WHEN** the container's main process exits (e.g., user types `exit` at the shell)
- **THEN** the PTY receives EOF, the terminal frontend closes the Tauri window, `WindowEvent::Destroyed` fires, the window is removed from `open_windows`, the genus is released, and the menu reverts to 🌱 pup

#### Scenario: Container crashes (OOM, process killed)
- **WHEN** the container exits abnormally
- **THEN** the same cleanup path as normal exit applies; the window closes, state is cleaned up, and the menu reverts to 🌱 pup

---

### Requirement: Window close triggers container stop
When the user closes a terminal window directly (clicking X), the associated container SHALL stop gracefully.

#### Scenario: User closes window via X
- **WHEN** the user closes the Tauri terminal window
- **THEN** SIGHUP is sent to the podman process; the container stops within the `--stop-timeout=10` grace period; the container is removed automatically via `--rm`; `WindowEvent::Destroyed` fires and cleanup completes

#### Scenario: Container does not stop within grace period
- **WHEN** SIGHUP is sent AND the container does not exit within 10 seconds
- **THEN** podman sends SIGKILL; the container is force-removed; cleanup proceeds normally

---

## MODIFIED Requirements

### Requirement: Menu bloom state requires open window (modifies tray-app)
The 🌺 bloom icon for a project's "Attach Here" menu item SHALL require both an open window AND a running container. Container running state alone is no longer sufficient.

#### Scenario: Container running, window open
- **WHEN** a project has a running container AND an entry in `open_windows` for AttachHere
- **THEN** the menu item shows 🌺 bloom

#### Scenario: Container running, no window open
- **WHEN** a project has a running container but no entry in `open_windows`
- **THEN** the menu item shows 🌱 pup (transitional state — container running but window not yet tracked or already closed)

#### Scenario: Window open, container not yet running
- **WHEN** a project has an entry in `open_windows` but the container is not yet in the running set
- **THEN** the menu item shows 🌱 pup (CREATING/bud state)

#### Scenario: No window, no container
- **WHEN** a project has no entry in `open_windows` and no running container
- **THEN** the menu item shows 🌱 pup

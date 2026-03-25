## ADDED Requirements

### Requirement: Tauri window hosts embedded terminal emulator

Each development environment and maintenance terminal SHALL be rendered as a Tauri-owned webview window containing an xterm.js terminal instance. No external terminal emulators are spawned.

#### Scenario: Attach Here creates a terminal window

- **WHEN** the user clicks "Attach Here" on a project and no window exists for that environment
- **THEN** a new Tauri window is created with:
  - Label: `tillandsias-<project>-<genus>` (matching the container name)
  - Title: `<Genus Display Name> -- <project-name>`
  - Default size: 960x640, resizable, minimum 480x320
  - Content: xterm.js terminal emulator connected to a PTY running the container

#### Scenario: Repeated Attach Here re-focuses existing window

- **WHEN** the user clicks "Attach Here" and a window with the matching label already exists
- **THEN** the existing window is focused (brought to front) and no new window or PTY is created

#### Scenario: Terminal renders full TUI applications

- **WHEN** a TUI application (OpenCode, vim, htop, less) runs inside the container
- **THEN** the embedded terminal correctly renders:
  - 256-color and truecolor escape sequences
  - Cursor movement and positioning
  - Alternate screen buffer (fullscreen apps)
  - Mouse events (clicks, scrolling, selection)
  - Unicode characters including CJK and emoji

#### Scenario: Terminal resize propagates to container

- **WHEN** the user resizes the Tauri window
- **THEN** xterm.js reflows to fill the new dimensions, the PTY is resized to match the new column and row count, and the container process receives SIGWINCH

#### Scenario: Copy and paste works in terminal

- **WHEN** the user selects text in the terminal and presses Ctrl+Shift+C (or Cmd+C on macOS)
- **THEN** the selected text is copied to the system clipboard
- **WHEN** the user presses Ctrl+Shift+V (or Cmd+V on macOS)
- **THEN** the clipboard contents are pasted into the terminal as keystrokes

#### Scenario: Maintenance terminal opens in window

- **WHEN** the user clicks the maintenance/ground terminal menu item for a project
- **THEN** a Tauri window opens with a terminal running a fish shell inside a forge container for that project, with the same security flags as Attach Here

#### Scenario: GitHub Login opens in window

- **WHEN** the user clicks "GitHub Login"
- **THEN** a Tauri window opens with a terminal running the gh-auth-login.sh script, and closes automatically when the script exits

### Requirement: Window lifecycle tied to container lifecycle

The terminal window and the container it represents SHALL have coupled lifecycles — neither outlives the other except during brief cleanup transitions.

#### Scenario: Container exit closes window

- **WHEN** the container process exits (user types `exit`, OpenCode quits, crash)
- **THEN** the PTY detects EOF, the window displays the exit status for 2 seconds, and then the window closes automatically

#### Scenario: Window close stops container

- **WHEN** the user closes the terminal window (X button, Alt+F4, Cmd+W)
- **THEN** the PTY master is dropped (sending SIGHUP to the container's init process), the container receives SIGTERM and has 10 seconds for graceful shutdown before SIGKILL, and after exit the container is removed (--rm)

#### Scenario: Container exit updates tray state

- **WHEN** a container exits (by any path — user exit, window close, crash)
- **THEN** the container is removed from `TrayState.running`, the genus allocation is released, the project's `assigned_genus` is cleared if no other environments remain, and the tray menu is rebuilt

### Requirement: Frontend loads without network access

The xterm.js library and its addons SHALL be vendored into `assets/frontend/vendor/` and loaded from the local filesystem. No CDN, no npm install, no network request is made during window creation.

#### Scenario: Offline terminal creation

- **WHEN** the system has no network connectivity
- **THEN** terminal windows still open and function correctly because all frontend assets are bundled with the application

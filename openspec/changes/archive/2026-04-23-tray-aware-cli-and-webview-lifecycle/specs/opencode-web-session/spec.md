## ADDED Requirements

### Requirement: OpenCode Web defaults to dark theme

The forge image SHALL ship a config-overlay file `tui.json` that sets the OpenCode UI theme to a built-in dark theme (`tokyonight`). Project-specific overrides via the user's own `~/.config/opencode/tui.json` (mounted from the project workspace) SHALL continue to win over the overlay default.

#### Scenario: Fresh attach uses dark theme
- **WHEN** a user attaches to a project with no project-level OpenCode theme override
- **THEN** OpenCode reads `theme: "tokyonight"` from `~/.config/opencode/tui.json`
- **AND** the rendered TUI/web UI uses the tokyonight dark palette

#### Scenario: Project override wins
- **WHEN** the project workspace contains a `~/.config/opencode/tui.json` (mounted in)
- **THEN** that file overrides the overlay default
- **AND** the user's chosen theme is rendered

### Requirement: Webview close does not terminate the tray

Closing a `WebviewWindow` whose label starts with `web-` SHALL close only that window. The tray icon, scanner, event loop, and all running containers SHALL remain alive.

#### Scenario: Single webview close
- **WHEN** the user closes a single `web-*` webview window
- **THEN** that window is destroyed
- **AND** the Tauri runtime does NOT emit `RunEvent::ExitRequested`
- **AND** the tray icon remains visible and responsive
- **AND** the underlying `tillandsias-<project>-forge` container keeps running

#### Scenario: Last webview close (no other windows)
- **WHEN** the user closes the only open webview window with no others present
- **THEN** the window is destroyed
- **AND** the Tauri runtime does NOT exit
- **AND** the tray icon and infrastructure persist

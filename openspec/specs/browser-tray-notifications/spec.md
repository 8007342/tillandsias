<!-- @trace spec:browser-tray-notifications -->

# browser-tray-notifications Specification

## Status

active

## Purpose

Browser launch operations provide visual feedback through tray notification chips. Users see "Launching browser" with a globe icon, transition to success/failure states, and auto-dismiss after 5 seconds. This gives confidence that browser operations are in progress and completes cleanly without manual dismissal.

## Requirements

### Requirement: Show "Launching browser" chip with withered globe

When a browser window launch starts, an in-progress notification appears.

#### Scenario: Chip shown on spawn start
- **WHEN** `handlers::handle_open_browser_window()` is called
- **THEN** add a `BuildProgress` entry with:
  - `image_name: "Browser"` (or `"Browser — <project>"`)
  - `status: InProgress`
  - Globe icon (🌐) displayed as withered (grayed out)

### Requirement: Update chip on success

On successful browser spawn, the chip shows completion with a green globe.

#### Scenario: Chip updates to success
- **WHEN** the browser container spawned successfully
- **AND** `spawn_chromium_window()` returns Ok
- **THEN** update the chip to:
  - `status: Completed`
  - Globe icon shown as green/active for 5s, then fadeout

### Requirement: Update chip on failure

On browser spawn failure, the chip shows error with a red icon and message.

#### Scenario: Chip updates to failure
- **WHEN** the browser container failed to spawn
- **AND** `spawn_chromium_window()` returns Err
- **THEN** update the chip to:
  - `status: Failed(reason)`
  - Globe icon shown as red (❌) for 5s, then fadeout
  - Message: `"Browser failed: <reason>"`

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — integration test required for S2→S3 progression

Gating points:
- BuildProgress chip created with InProgress status on spawn initiation
- Icon and message update correctly for success (green globe, "Completed")
- Icon and message update correctly for failure (red X, "Failed: <reason>")
- Chip auto-dismisses after 5 seconds
- Multiple concurrent chips stack without overlap

## Observability

Annotations referencing this spec:
```bash
grep -rn "@trace spec:browser-tray-notifications" src-tauri/ scripts/ crates/ --include="*.rs"
```

Log events SHALL include:
- `spec = "browser-tray-notifications"` on notification events
- `notification_status = "in_progress|completed|failed"` tracking chip state transitions
- `notification_dismissed = true` when chip auto-fades
- `browser_launch_outcome = "success|failure"` for analytics

## Sources of Truth

- `cheatsheets/ux/tray-notification-patterns.md` — BuildProgress chip lifecycle and state machine
- `cheatsheets/ux/icon-library.md` — globe icon and state variants (withered, active, error)
- `cheatsheets/ux/fadeout-timing.md` — 5-second auto-dismiss pattern matching build chip behavior

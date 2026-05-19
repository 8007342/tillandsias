# tray-ui-integration Specification

@trace spec:tray-ui-integration

## Status

active

## Requirements

### Requirement: Native tray integration matches platform expectations

Native tray builds MUST use the platform tray/status notifier integration appropriate for the target desktop while keeping launcher behavior traceable to tray state.

#### Scenario: Tray UI dependency is enabled

- **WHEN** the native tray build is selected
- **THEN** required tray UI dependencies MAY be included
- **AND** headless portable builds MUST remain separable from those UI dependencies

## Sources of Truth

- `cheatsheets/runtime/statusnotifier-tray.md` - Linux tray/status notifier behavior
- `cheatsheets/welcome/tray-minimal-ux.md` - User-facing tray expectations


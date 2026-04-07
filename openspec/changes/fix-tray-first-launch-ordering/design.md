# Design: Fix tray first-launch ordering

## Architecture

The existing `forge_available` flag and menu gating are already correct. The gap is user feedback: the user cannot tell that setup is in progress or that something failed.

## Changes

### 1. Forge-readiness guard in `handle_attach_here` (handlers.rs)

Before any work, check `state.forge_available`. If false, send a desktop notification with the i18n string `notifications.forge_not_ready` and return early with an error. This is defense-in-depth — the menu should already be disabled, but this catches any race condition or future code path that bypasses the menu gate.

### 2. Startup "Setting up..." chip (main.rs)

After the tray is displayed but before forge image check begins, add a "Setting up..." build chip to `active_builds` when the forge image is not yet confirmed present. This chip is visible in the menu immediately, telling the user that setup is in progress. When the forge check/build completes, the chip transitions to completed/failed normally via the existing build progress system.

### 3. Infrastructure failure notification (main.rs)

At line 378-380, when `ensure_infrastructure_ready` fails, send a desktop notification so the user knows infrastructure setup failed. The tray continues operating (forge builds can still work without the proxy cache), but the user is informed.

### 4. i18n strings

New keys in all locale files:
- `notifications.forge_not_ready` — "Setting up... please wait a moment."
- `notifications.infrastructure_failed` — "Setup encountered an issue. Some features may be slow."

## Trace

@trace spec:tray-app

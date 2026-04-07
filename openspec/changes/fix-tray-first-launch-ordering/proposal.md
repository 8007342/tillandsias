# Proposal: Fix tray first-launch ordering

## Problem

On a fresh install, the user can launch the tray app before infrastructure (proxy, forge images) is built. The `install.sh` script runs `--init` as a background `nohup` process, so the tray may start before images exist.

Currently:
- **Infrastructure failure is silent**: `main.rs:378` logs a `warn!()` but the tray continues in a degraded state with no user-facing feedback.
- **Menu items are disabled but unexplained**: `forge_available` starts `false`, which correctly disables "Attach Here" items, but the user sees no explanation of WHY they are disabled or WHEN they will become available.
- **`handle_attach_here` has no forge-readiness guard**: If called directly (e.g., from a race condition or future code path), it proceeds to build images inline, which can take minutes with no tray-level feedback.

## Solution

1. **Add a forge-readiness guard in `handle_attach_here`**: Return early with a desktop notification explaining the situation when `forge_available` is false.
2. **Show "Setting up..." build chip during startup**: When the forge is not yet available during startup, display a visible build chip in the menu so the user understands why items are disabled.
3. **Send desktop notification on infrastructure failure**: Replace the silent `warn!()` with a user-visible notification.
4. **Add i18n strings**: All new user-facing text goes through the i18n system.

## Non-goals

- Don't block the tray UI or make it unresponsive.
- Don't change the async architecture.
- Don't modify `install.sh` (the tray-side fix is sufficient).

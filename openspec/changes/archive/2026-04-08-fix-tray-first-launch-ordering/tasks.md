# Tasks: Fix tray first-launch ordering

## Implementation

- [x] T1: Add `notifications.forge_not_ready` and `notifications.infrastructure_failed` to `locales/en.toml`
- [x] T2: Add same keys to all other locale files (es, ja, zh-Hant, zh-Hans, ar, ko, hi, ta, te, fr, pt, it, ro, ru, nah, de)
- [x] T3: Add forge-readiness guard at top of `handle_attach_here` in `handlers.rs`
- [x] T4: Add startup "Setting up..." chip in `main.rs` when forge image not yet confirmed
- [x] T5: Replace silent `warn!()` with desktop notification on infrastructure failure in `main.rs`
- [x] T6: Add `@trace spec:tray-app` annotations to new/modified code
- [x] T7: Run `cargo test --workspace` and verify

## Verification

- Fresh install: tray shows "Setting up..." chip while images build, "Attach Here" is disabled
- Clicking disabled "Attach Here" does nothing (menu is grayed out)
- If a code path bypasses the menu gate, `handle_attach_here` returns early with notification
- Infrastructure failure shows desktop notification
- After build completes, "Attach Here" becomes enabled, chip shows "ready"

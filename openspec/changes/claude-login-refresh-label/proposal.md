## Why

Authenticated Claude shows "Claude (authenticated)" which is inconsistent with GitHub's "GitHub Login Refresh" pattern. Should match.

## What Changes

- "🔒 Claude (authenticated)" [disabled] → "🔒 Claude Login Refresh" [enabled/clickable]
- Users can re-enter their API key to refresh it, matching the GitHub flow

## Capabilities
### New Capabilities
### Modified Capabilities
## Impact
- **Modified file**: `src-tauri/src/menu.rs` — one line change

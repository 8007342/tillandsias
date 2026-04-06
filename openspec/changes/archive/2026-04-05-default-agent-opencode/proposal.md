## Why
OpenCode should be the default agent for new installations — it's open source and doesn't require an API key. Users can switch to Claude from the Settings menu.

## What Changes
- Change `SelectedAgent::default()` from `Claude` to `OpenCode`

## Capabilities
### New Capabilities
_None_
### Modified Capabilities
- `environment-runtime`: Default agent changes from Claude to OpenCode

## Impact
- crates/tillandsias-core/src/config.rs — one-line change in Default impl

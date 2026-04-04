## Why

Phases 1-4 built the full enclave architecture: proxy, git mirror, offline forge, and inference. The accountability windows (`--log-proxy`, `--log-enclave`, `--log-git`) were added but need real telemetry events populated throughout the codebase. Documentation needs final updates to reflect the complete architecture.

## What Changes

- Ensure all enclave operations emit structured tracing events with correct specs and accountability tags
- Update CLAUDE.md with enclave architecture section
- Update all cheatsheets to reflect complete 5-phase architecture
- Final trace annotation sweep across all new code
- Archive all 5 OpenSpec changes

## Capabilities

### Modified Capabilities
- `runtime-logging`: Ensure all accountability windows have real events

### New Capabilities
- (none — polish only)

## Impact

- **Modified**: tracing events in handlers.rs, event_loop.rs, runner.rs
- **Modified**: CLAUDE.md, cheatsheets
- **OpenSpec**: Archive 5 changes

<!-- @trace spec:browser-debounce -->

# browser-debounce Specification

## Status

active

## Purpose

Rapid browser window spawns from automated agents are debounced to prevent resource exhaustion. A 10-second window per project prevents duplicate windows while allowing manual debug windows to bypass the check. Window timing is tracked per project to enable responsive user experience.

## Requirements

### Requirement: Debounce browser window spawns per project

Safe browser window spawns are rate-limited to one per 10-second interval per project.

#### Scenario: Debounce prevents rapid spawns
- **WHEN** an agent calls `open_safe_window(url)` for a project
- **AND** a browser window was already spawned for that project in the last 10 seconds
- **THEN** the new request is rejected with error: `"Debounced: wait Ns before opening another window for <project>"`
- **RATIONALE**: Prevent rapid-fire spawns from agents. 10s window matches build chip fadeout pattern.

### Requirement: Track debounce timing per project

Spawn timestamps are tracked in `TrayState.browser_last_launch: HashMap<String, Instant>`.

#### Scenario: Timestamp updated on spawn
- **WHEN** `handle_open_browser_window()` is called
- **THEN** the timestamp map is checked: if `now - last_launch < 10s`, reject; otherwise update timestamp and proceed

### Requirement: Debounce applies to safe windows only

Debug windows are manually triggered and bypass the debounce check.

#### Scenario: Debug window skips debounce
- **WHEN** `open_debug_window()` is called
- **THEN** debounce is NOT applied
- **RATIONALE**: Debug windows are manually triggered, rare, and should not be rate-limited.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — integration test required for S2→S3 progression

Gating points:
- Safe window rejected if spawned within 10 seconds of previous spawn (same project)
- Error message includes remaining wait time
- Debug window bypasses debounce check entirely
- Timestamp is correctly updated after successful spawn

## Observability

Annotations referencing this spec:
```bash
grep -rn "@trace spec:browser-debounce" src-tauri/ scripts/ crates/ --include="*.rs"
```

Log events SHALL include:
- `spec = "browser-debounce"` on debounce events
- `browser_debounced = true` when request is rejected
- `debounce_remaining_ms = N` showing time until next window allowed
- `browser_spawned = true` when request succeeds

## Sources of Truth

- `cheatsheets/runtime/request-rate-limiting.md` — debounce patterns and timing strategies
- `cheatsheets/ux/feedback-patterns.md` — user messaging for rate-limited operations

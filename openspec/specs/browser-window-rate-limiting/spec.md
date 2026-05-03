<!-- @trace spec:browser-window-rate-limiting -->

# browser-window-rate-limiting Specification

## Status

status: active
annotation-count: 2
derived-from: code annotations only (no archive)
last-updated: 2026-05-02

## Purpose

Defines per-project minimum time interval enforcement between browser window open requests. Prevents window request spam by rejecting requests that arrive within 10 seconds of the previous request for the same project.

## Requirements

### Requirement: Per-Project Debouncing

The browser window handler MUST maintain a per-project timestamp to track the last time a window was opened for each project.

- **Granularity**: Per project (by project name, not by URL or service)
- **Interval**: MUST be 10 seconds minimum between window opens for the same project
- **Tracking**: MUST use `WindowDebounce` struct with `HashMap<String, Instant>`
- **Reset**: Timestamp MUST update only when a request is ALLOWED (not when rejected)

#### Scenario: First window request

- **WHEN** agent requests `open_safe_window("opencode.my-app.localhost")` for project `"my-app"`
- **AND** no previous window record exists for `"my-app"`
- **THEN** request MUST be ALLOWED
- **AND** timestamp MUST be recorded for `"my-app"`
- **AND** browser window MUST be spawned

#### Scenario: Second request within interval

- **WHEN** agent requests `open_safe_window("dashboard.localhost")` 5 seconds after first request
- **AND** both requests are for project `"my-app"`
- **THEN** request MUST be REJECTED
- **AND** MUST return error: "Window request too frequent; minimum interval is 10 seconds"
- **AND** timestamp MUST NOT be updated (remains at first request)
- **AND** no window spawned

#### Scenario: Second request after interval elapsed

- **WHEN** agent requests window 11 seconds after first request
- **AND** same project `"my-app"`
- **THEN** request MUST be ALLOWED
- **AND** timestamp MUST be updated to new request time
- **AND** window MUST be spawned

### Requirement: Independent Project Tracking

Window request rates for different projects MUST NOT interfere with each other.

- **Isolation**: Each project MUST maintain separate debounce state
- **No cross-project limits**: Project A window requests MUST NOT block project B requests
- **Use case**: User working on two projects in parallel MUST be able to open windows for each independently

#### Scenario: Multiple projects

- **WHEN** agent in project `"frontend"` opens window at T=0
- **AND** agent in project `"backend"` opens window at T=5 seconds
- **THEN** backend window MUST be ALLOWED (different project)
- **AND** both windows MUST spawn
- **AND** timestamps MUST be tracked separately: frontend=T0, backend=T5

#### Scenario: Same project, staggered intervals

- **WHEN** project `"my-app"` requests windows at T=0, T=5, T=15
- **THEN** window at T=0: MUST be ALLOWED (first)
- **AND** window at T=5: MUST be REJECTED (within 10-second interval)
- **AND** window at T=15: MUST be ALLOWED (10+ seconds elapsed)

### Requirement: Integration with URL Validation

Rate limiting MUST occur AFTER URL validation but BEFORE socket communication.

#### Request Processing Order

1. Validate URL (safe or debug pattern check) — Requirement in `browser-mcp-server`
2. Extract project from environment (`TILLANDSIAS_PROJECT`)
3. **Check rate limit** — this requirement
4. If allowed: Forward to tray socket
5. If rejected: Return error to agent

#### Scenario: Invalid URL + rate limit

- **WHEN** agent requests invalid URL AND within debounce interval
- **THEN** validation MUST fail FIRST
- **AND** MUST return validation error (rate limit check skipped)
- **AND** timestamp MUST NOT be updated

#### Scenario: Valid URL + rate limit

- **WHEN** agent requests valid URL AND within debounce interval
- **THEN** validation MUST pass
- **AND** rate limit check MUST reject
- **AND** MUST return error: "Window request too frequent"
- **AND** timestamp MUST NOT be updated
- **AND** socket MUST NOT be contacted

### Requirement: Debounce Configuration

The debounce interval MUST be configurable and MUST default to 10 seconds.

- **Default**: MUST be 10 seconds
- **Field**: MUST be `debounce_secs: u64` in `WindowDebounce` struct
- **Configuration**: MUST be hardcoded in source (no runtime config file)
- **No overrides**: Environment variables MUST NOT override debounce interval

### Requirement: Stateless Per-Request Handling

Each window request handler invocation MUST check and update debounce state atomically.

- **State**: MUST be stored in global `Mutex<WindowDebounce>` (thread-safe)
- **Atomicity**: Lock MUST be acquired at start, released after timestamp update
- **No prediction**: Handler MUST NOT pre-check; validation MUST happen at request time

#### Scenario: Concurrent requests (same project)

- **WHEN** two concurrent agents (same project) submit requests within interval
- **THEN** first request MUST acquire lock, check timestamp, ALLOW, update
- **AND** second request MUST acquire lock, check updated timestamp, REJECT
- **AND** no race condition; mutex MUST serialize access

### Requirement: Logging

Rate limit rejections MUST emit DEBUG-level logs for troubleshooting.

- **Level**: MUST be DEBUG (verbose, for developer troubleshooting)
- **Format**: MUST include project, reason, and next allowed time if useful
- **No accountability**: Rate limiting is operational, not sensitive

#### Log Example

```
DEBUG browser: Window request rate-limited {project=my-app, elapsed_secs=5, min_required_secs=10}
  @trace spec:browser-window-rate-limiting
```

## Sources of Truth

- `cheatsheets/runtime/logging-levels.md` — DEBUG-level logging conventions

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Related Specifications

- `browser-mcp-server` — MCP server and URL validation (executed before rate limit)
- `browser-isolation-core` — Chromium container orchestration (executed after rate limit)

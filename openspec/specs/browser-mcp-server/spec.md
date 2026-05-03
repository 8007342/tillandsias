<!-- @trace spec:browser-mcp-server -->

# browser-mcp-server Specification

## Status

status: active
annotation-count: 15
derived-from: code annotations only (no archive)
last-updated: 2026-05-02

## Purpose

Defines the MCP (Model Context Protocol) server that agents running in forge containers use to request browser window operations from the system tray. The server listens on stdin/stdout, receives tool calls from agents, validates URLs and rate limits, and forwards safe window requests to the tray via Unix socket IPC.

## Requirements

### Requirement: MCP Server Protocol Implementation

The browser MCP server SHALL implement the Model Context Protocol 2024-11-05 specification and expose exactly two tools to agents:

#### Tool: open_safe_window

- **Purpose**: Open a URL in an isolated browser window with read-only constraints
- **Input schema**: `{ "url": string }` — the URL to open (required)
- **Response**: JSON success or error message
- **Validation**: URL MUST match safe pattern (see URL Validation requirement)
- **Isolation**: Window spawns with dark theme, hidden address bar, no developer tools

#### Tool: open_debug_window

- **Purpose**: Open a URL in a browser window with developer tools enabled on port 9222
- **Input schema**: `{ "url": string }` — the URL to open (required)
- **Response**: JSON success or error message
- **Validation**: URL MUST match debug pattern (see URL Validation requirement)
- **Constraints**: Debug tools available only for project-scoped services, not external URLs or dashboard

#### Scenario: Agent requests safe window

- **WHEN** agent calls `open_safe_window("opencode.my-project.localhost")`
- **THEN** MCP server validates URL against safe pattern (`<service>.<project>.localhost` or `dashboard.localhost`)
- **AND** forwards request to tray socket at `/run/tillandsias/tray.sock` with action `"open_safe_window"`
- **AND** returns success response if tray accepts request, error response if validation fails

#### Scenario: Agent requests debug window

- **WHEN** agent calls `open_debug_window("service.my-project.localhost")`
- **THEN** MCP server validates URL is NOT `dashboard.localhost` and matches `<service>.<project>.localhost` pattern
- **AND** forwards request to tray with action `"open_debug_window"`
- **AND** DevTools become available on port 9222

### Requirement: Unix Socket IPC Protocol

The MCP server SHALL communicate with the tray app via Unix domain socket at `/run/tillandsias/tray.sock`.

#### Message Format

WindowRequest struct (JSON serialization):
```json
{
  "action": "open_safe_window" | "open_debug_window",
  "url": "<validated-url>",
  "project": "<project-name>"
}
```

- `action`: String, one of two allowed values
- `url`: String, pre-validated against safe or debug patterns
- `project`: String, extracted from environment variable `TILLANDSIAS_PROJECT`

#### Scenario: Socket communication

- **WHEN** MCP server receives tool call with valid parameters
- **THEN** serialize to WindowRequest struct
- **AND** write to Unix socket connected to tray
- **AND** await response from tray (timeout: 5 seconds default)
- **AND** return response to agent via MCP protocol

#### Scenario: Socket unavailable

- **WHEN** `/run/tillandsias/tray.sock` does not exist or connection fails
- **THEN** log error at WARN level
- **AND** return error response to agent: "Tray socket unavailable"
- **AND** do NOT retry (agent responsibility to retry)

### Requirement: URL Validation

The MCP server SHALL implement two distinct URL validation functions based on window action type.

#### Safe Window URL Validation

Safe windows permit URLs matching:
1. `dashboard.localhost` — global dashboard, read-only
2. `<service>.<project>.localhost` — project-scoped services (e.g., `opencode.my-app.localhost`)

Rejected patterns:
- External URLs (http://, https://, or any non-localhost domain)
- `<service>.localhost` without project component (ambiguous scope)
- URLs with suspicious characters or path traversal attempts

#### Debug Window URL Validation

Debug windows are MORE restrictive than safe windows:
1. `<service>.<project>.localhost` ONLY — project-scoped services
2. `dashboard.localhost` is EXPLICITLY REJECTED (no global debug access)
3. All external URLs rejected

#### Scenario: Safe window validation

- **WHEN** agent requests URL `"opencode.my-project.localhost"`
- **THEN** validation passes (matches `<service>.<project>.localhost` pattern)

- **WHEN** agent requests URL `"dashboard.localhost"`
- **THEN** validation passes for safe window only

- **WHEN** agent requests URL `"https://github.com"`
- **THEN** validation fails, return error "Invalid URL for safe window"

#### Scenario: Debug window validation

- **WHEN** agent requests URL `"dashboard.localhost"` with `open_debug_window`
- **THEN** validation fails, return error "Debug windows do not support dashboard access"

### Requirement: Project Context Injection

The MCP server SHALL require the environment variable `TILLANDSIAS_PROJECT` to be set by the forge container at startup.

- **Extraction**: Read `TILLANDSIAS_PROJECT` on server initialization
- **Fallback**: If unset, log WARN and default to `"unknown"`
- **Usage**: Include project name in WindowRequest struct sent to tray
- **Validation**: URLs MUST match the project extracted from environment (e.g., if `TILLANDSIAS_PROJECT="my-app"`, only URLs matching `*.my-app.localhost` are valid for debug windows)

#### Scenario: Project context

- **WHEN** forge container starts with `TILLANDSIAS_PROJECT=backend-service`
- **THEN** MCP server reads environment on startup
- **AND** rejects debug window requests for `opencode.other-project.localhost` (project mismatch)
- **AND** accepts debug window requests for `opencode.backend-service.localhost`

### Requirement: Logging and Diagnostics

The MCP server SHALL emit structured logs at INFO level for successful window requests and WARN/ERROR for failures.

- **Log format**: Follow `logging-levels` cheatsheet INFO/WARN/ERROR guidelines
- **Successful request**: `"Browser window opened {action=open_safe_window, url=opencode.my-project.localhost, project=my-app}"`
- **Validation failure**: `"URL validation failed {action=open_debug_window, reason=dashboard.localhost not allowed in debug mode}"`
- **Socket error**: `"Tray socket unavailable {path=/run/tillandsias/tray.sock, error=Connection refused}"`
- **No accountability fields required** for browser requests (they are not sensitive operations)

### Requirement: Error Handling and Recovery

The MCP server SHALL handle errors gracefully and return meaningful error messages to agents.

#### Error Cases

1. **Invalid tool call**: Tool not recognized (only `open_safe_window` and `open_debug_window` exist)
   - Return: MCP error response with reason
2. **Missing URL parameter**: Required field absent
   - Return: MCP error response "URL parameter required"
3. **Invalid URL**: Fails safe or debug validation
   - Return: MCP error response "Invalid URL for [safe|debug] window: <reason>"
4. **Socket unavailable**: Tray socket not reachable
   - Return: MCP error response "Tray application not available"
5. **Tray timeout**: No response from tray within 5 seconds
   - Return: MCP error response "Browser service timeout"

#### Scenario: Agent provides invalid URL

- **WHEN** agent calls `open_safe_window("file:///etc/passwd")`
- **THEN** validation fails immediately
- **AND** MCP server returns error: "Invalid URL for safe window: file:// scheme not allowed"
- **AND** socket is NOT contacted

## Sources of Truth

- `cheatsheets/runtime/logging-levels.md` — Log level conventions and INFO/WARN/ERROR semantics
- `cheatsheets/runtime/browser-isolation.md` — Browser window isolation and security constraints (if exists)

## Related Specifications

- `browser-isolation-core` — Chromium container orchestration and isolation engine
- `browser-isolation-framework` — Framework for additional browser window features
- `browser-window-rate-limiting` — Per-project debounce for window open requests

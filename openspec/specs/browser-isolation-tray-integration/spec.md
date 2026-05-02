<!-- @trace spec:browser-isolation-tray-integration -->
# browser-isolation-tray-integration Specification

## Purpose
Define how the tray menu integrates with browser isolation containers to launch safe, isolated browser windows for OpenCode Web and other web-based tools.

## Requirements

### Requirement: OpenCode Web launches in browser isolation
When a user clicks the "🌐 OpenCode Web" action button in a project submenu:
1. An OpenCode Web container is launched (persistent, per-project)
2. Once the container is healthy, a browser window is launched in `tillandsias-chromium-core`
3. The browser communicates with OpenCode Web via the project's enclave network
4. No host system browser is used; all browsing is isolated and sandboxed

@trace spec:browser-isolation-core

#### Scenario: First-time OpenCode Web launch
- **WHEN** user clicks 🌐 OpenCode Web for a project
- **THEN** an OpenCode Web container is created (if not already running)
- **AND** once the container is healthy (OpenCode HTTP server responds), a browser window is spawned
- **AND** the browser launches inside `tillandsias-chromium-core` container with safe window type

#### Scenario: Reattach to existing OpenCode Web
- **WHEN** user clicks 🌐 OpenCode Web for a project that already has a running container
- **THEN** no new container is created (reuse the existing one)
- **AND** a new browser window is opened against the healthy container
- **AND** multiple browser windows can attach to the same container concurrently

### Requirement: Versioned image tags for reproducibility
The browser isolation containers MUST use versioned image tags (e.g., `tillandsias-chromium-core:v0.1.160`)
instead of `:latest` to ensure reproducible launches across sessions.

#### Scenario: Browser container uses correct version tag
- **WHEN** a browser window is launched
- **THEN** the container image used is `tillandsias-chromium-core:v{VERSION}`
- **AND** the version is passed from the tray application's TILLANDSIAS_FULL_VERSION
- **AND** the version is used consistently across all browser container launches

### Requirement: Safe window type by default
The browser window launched for OpenCode Web SHALL use safe window type:
- Headless mode: no visible Chromium UI, only the application's web interface
- No dev tools or debugging interfaces exposed to the user
- Remote debugging port NOT exposed (port 9222 is internal only)
- Security flags applied: CAP_DROP=ALL, no new privileges, read-only root

#### Scenario: Safe browser launch
- **WHEN** 🌐 OpenCode Web is clicked
- **THEN** the browser launches with `--headless=new` flag
- **AND** no remote debugging port is exposed
- **AND** all OWASP Top 10 security flags are applied

### Requirement: Browser container network isolation
The browser container has read-only access to the project's enclave network:
- Can reach OpenCode Web container at its enclave IP
- Cannot reach the host system or other projects' containers
- No direct internet access (proxied through `tillandsias-proxy` if needed)
- Cannot access host credentials, keys, or secrets

@trace spec:enclave-network, spec:podman-orchestration

#### Scenario: Browser communicates with OpenCode Web
- **WHEN** browser window is launched
- **THEN** OpenCode Web is accessible at `<project>.localhost:<port>` within the enclave
- **AND** the browser container is on the same enclave network as OpenCode Web
- **AND** no credentials from the project are visible to the browser container

### Requirement: Browser window lifecycle
A browser window launched from the tray:
1. Opens in response to user action (not automatically at startup)
2. Runs inside an ephemeral container (`--rm` flag applied)
3. Exits when the user closes the browser window
4. Does NOT keep the OpenCode Web container running (independent lifecycles)
5. Subsequent clicks on OpenCode Web reattach to the persistent container and launch a new browser

#### Scenario: Browser window closes
- **WHEN** user closes the browser window
- **THEN** the browser container is removed (`--rm` behavior)
- **AND** the OpenCode Web container continues running
- **AND** subsequent clicks on OpenCode Web reuse the running container

#### Scenario: OpenCode Web container stops
- **WHEN** OpenCode Web container is manually stopped or crashes
- **THEN** the next click on OpenCode Web launches a new container
- **AND** any browser windows attached to the old container are unaffected (stale tabs)

### Requirement: No Tauri webview path
The tray application SHALL NOT use Tauri's native webview for OpenCode Web.
All web-based interfaces are launched through browser isolation containers only.

@trace spec:browser-isolation-core, spec:tray-minimal-ux
@tombstone opencode-web-session (webview-based flow)

#### Scenario: OpenCode Web never uses native webview
- **WHEN** 🌐 OpenCode Web is clicked
- **THEN** the browser isolation container path is always used
- **AND** Tauri's webview API is never called
- **AND** no native window/webview is created on the host system

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` — Container lifecycle states and health checks
- `cheatsheets/runtime/podman-logging.md` — Debugging container startup and health issues
- `openspec/specs/browser-isolation-core/spec.md` — Core browser isolation container requirements
- `openspec/specs/enclave-network/spec.md` — Network isolation and enclave architecture

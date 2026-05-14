<!-- @trace spec:browser-isolation-tray-integration -->
# browser-isolation-tray-integration Specification

## Status

active

## Purpose
Define how the tray menu integrates with browser isolation containers to launch
safe GUI browser windows for OpenCode Web and other web-based tools.

## Requirements

### Requirement: OpenCode Web launches in browser isolation
When a user clicks the "🌐 OpenCode Web" action button in a project submenu:
1. An OpenCode Web container is launched (persistent, per-project)
2. Once the container is healthy, a GUI browser window is launched in
   `tillandsias-chromium-framework` through the compiled Podman launch path
   in `tillandsias-headless`
3. The browser reaches OpenCode Web through the published project-local host
   route `http://opencode.<project>.localhost/`
4. No host system browser is used for tray-driven OpenCode Web; the browser
   container consumes the runtime CA bundle for the secure session and is
   launched only through the compiled typed Podman path
5. The OpenCode Web attach flow SHALL remain OTP-authenticated and session-
   cookie protected per `spec:opencode-web-session-otp`
6. The compiled binary SHALL build the browser launch profile through the
   typed Podman layer and the baked Chromium framework containerfile; shell
   wrappers MAY exist for developer litmuses but MUST NOT be required at
   runtime

@trace spec:browser-isolation-core

#### Scenario: First-time OpenCode Web launch
- **WHEN** user clicks 🌐 OpenCode Web for a project
- **THEN** an OpenCode Web container is created (if not already running)
- **AND** once the container is healthy (OpenCode HTTP server responds), a
  browser window is spawned
- **AND** the browser launches inside `tillandsias-chromium-framework` via
  the compiled Podman browser launch path in safe GUI app mode

#### Scenario: Reattach to existing OpenCode Web
- **WHEN** user clicks 🌐 OpenCode Web for a project that already has a running
  container
- **THEN** no new container is created (reuse the existing one)
- **AND** a new browser window is opened against the healthy container
- **AND** multiple browser windows can attach to the same container
  concurrently

### Requirement: Content-hash identity with human aliases for reproducibility
The browser isolation containers MUST use a content-hash canonical tag for
reproducible launches across sessions. Human-facing CalVer-style tags MAY
remain as aliases, but `:latest` MUST NOT be the authoritative identity.

#### Scenario: Browser container uses correct canonical tag
- **WHEN** a browser window is launched
- **THEN** the container image used is the canonical content-hash tag for
  `tillandsias-chromium-core`
- **AND** the tray MAY refresh the human-facing version alias from
  `TILLANDSIAS_FULL_VERSION`
- **AND** the canonical tag is used consistently across all browser container
  launches

### Requirement: Safe window type by default
The browser window launched for OpenCode Web SHALL use safe window type:
- Visible GUI Chromium window in app mode with no tabs or URL bar
- No dev tools or debugging interfaces exposed to the user
- Remote debugging port NOT exposed (port 9222 is internal only)
- Security flags applied: CAP_DROP=ALL, no new privileges, read-only root

#### Scenario: Safe browser launch
- **WHEN** 🌐 OpenCode Web is clicked
- **THEN** the browser launches with `--app=http://opencode.<project>.localhost/`
- **AND** no remote debugging port is exposed
- **AND** all OWASP Top 10 security flags are applied

### Requirement: Browser launcher uses the secure OpenCode Web session
The browser launcher SHALL reach OpenCode Web through the published
project-local host route `http://opencode.<project>.localhost/`. The browser
container SHALL inherit the runtime CA bundle for the session and shall only
launch after the OpenCode Web OTP/session gate is healthy.

@trace spec:host-chromium-on-demand, spec:podman-orchestration, spec:opencode-web-session-otp, spec:reverse-proxy-internal, spec:podman-secrets-integration, spec:secrets-management

#### Scenario: Browser communicates with OpenCode Web
- **WHEN** browser window is launched
- **THEN** OpenCode Web is accessible at `opencode.<project>.localhost/`
  through the published route after the OTP/session gate passes
- **AND** the browser launcher inherits the runtime CA bundle for the session
- **AND** no credentials from the project are visible to the browser container

### Requirement: Browser window lifecycle
A browser window launched from the tray:
1. Opens in response to user action (not automatically at startup)
2. Runs inside an ephemeral container (`--rm` flag applied)
3. Exits when the user closes the browser window
4. Does NOT keep the OpenCode Web container running (independent lifecycles)
5. Subsequent clicks on OpenCode Web reattach to the persistent container and
   launch a new browser
6. If the browser image tag or launch contract changes, the previous browser
   container MUST be removed and a fresh container MUST be created
7. Browser containers MUST NOT share cache or state between runs
8. Host-side Podman rootless state MAY be repaired once if it is stale and
   recoverable; if Podman is missing or repair fails, the launcher MUST fail
   fast with an actionable error and MUST NOT pretend the browser was launched

#### Scenario: Browser window closes
- **WHEN** user closes the browser window
- **THEN** the browser container is removed (`--rm` behavior)
- **AND** the OpenCode Web container continues running
- **AND** subsequent clicks on OpenCode Web reuse the running container

#### Scenario: OpenCode Web container stops
- **WHEN** OpenCode Web container is manually stopped or crashes
- **THEN** the next click on OpenCode Web launches a new container
- **AND** any browser windows attached to the old container are unaffected
  (stale tabs)

#### Scenario: Browser image or contract mismatch
- **WHEN** the browser image tag changes or the launch contract hash no longer
  matches
- **THEN** the tray MUST remove the old browser container
- **AND** MUST launch a fresh browser container with no shared cache or state
- **AND** any stale browser temp files MUST be cleaned up as part of shutdown

#### Scenario: Stale host Podman state
- **WHEN** the browser launcher detects stale rootless Podman storage or
  uid-map metadata
- **THEN** it MAY attempt a single host-side `podman system migrate`
- **AND** if the repair succeeds, it MUST recreate the ephemeral browser
  container
- **AND** if the repair fails or `podman` is missing, it MUST fail fast with an
  actionable error

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

- `cheatsheets/runtime/container-lifecycle.md` — Container lifecycle states and
  health checks
- `cheatsheets/runtime/podman-logging.md` — Podman diagnostics, lifecycle
  recovery, and host maintenance
- `cheatsheets/runtime/runtime-logging.md` — Runtime logging and tracing best
  practices
- `cheatsheets/runtime/testing-best-practices.md` — lightweight unit-test and
  litmus patterns for health-gated startup
- `crates/tillandsias-headless/src/main.rs` — tray/OpenCode Web startup and
  GUI browser orchestration
- `crates/tillandsias-podman/src/container_spec.rs` — typed Podman launch
  profile builder for browser containers
- `images/chromium/Containerfile.framework` — baked Chromium framework image
  contract for the GUI browser
- `openspec/specs/browser-isolation-core/spec.md` — Core browser isolation
  container requirements
- `openspec/specs/host-chromium-on-demand/spec.md` — bundled Chromium runtime
  and app-mode launch contract
- `openspec/specs/opencode-web-session-otp/spec.md` — OTP and session-cookie
  protection for OpenCode Web attaches
- `openspec/specs/reverse-proxy-internal/spec.md` — CA chain and HTTPS
  termination for the OpenCode Web route
- `openspec/specs/podman-secrets-integration/spec.md` — runtime CA transport
  for the browser/session stack
- `openspec/specs/secrets-management/spec.md` — secure session secret lifecycle
  and cleanup

## Litmus Chain

Start with the browser core and the tray browser bridge before widening to the
OpenCode Web startup sequence:

1. `./scripts/run-litmus-test.sh browser-isolation-core`
1. `./scripts/run-litmus-test.sh browser-tray-launch-profile`
1. `./scripts/run-litmus-test.sh opencode-web-session-otp`
1. `./scripts/run-litmus-test.sh opencode-web-startup-sequence`
1. `./scripts/run-litmus-test.sh host-browser-mcp`
1. `./scripts/run-litmus-test.sh security-privacy-isolation`
1. `./build.sh --ci --strict --filter browser-isolation-core:browser-isolation-tray-integration:host-browser-mcp:opencode-web-session-otp:opencode-web-startup-sequence:security-privacy-isolation`
1. `./build.sh --ci-full --install --strict --filter browser-isolation-core:browser-isolation-tray-integration:host-browser-mcp:opencode-web-session-otp:opencode-web-startup-sequence:security-privacy-isolation`
1. `tillandsias --tray --opencode-web ~/src/visual-chess`

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:browser-tray-launch-profile`
- `litmus:opencode-web-startup-sequence`
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are
  destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:browser-isolation-tray-integration" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

<!-- @trace spec:chromium-debug-variant -->

# chromium-debug-variant Specification

## Status

active

## Purpose

Unrestricted, ephemeral Chromium variant for testing and debugging. Runs with all domains accessible, DevTools enabled, extensions allowed, and verbose logging. Profile and cache are tmpfs-backed and destroyed on shutdown. Designed for engineers testing web features in development environments without production safety constraints.

This spec ensures:
- Full network access (no allowlist)
- Developer tools enabled (DevTools, console)
- Extensions and plugins allowed for testing
- Verbose logging of all network activity
- Session isolation (no credential persistence across runs)

## Requirements

### Requirement: Unrestricted domain access

All domains MUST be accessible from the debug-variant browser.

#### Scenario: Any domain allowed
- **WHEN** the user navigates to any domain (internal, external, localhost)
- **THEN** the request MUST be allowed and reach the destination
- **AND** no allowlist MUST be enforced
- **AND** full HTTP and HTTPS access MUST be available

#### Scenario: Localhost and non-standard ports
- **WHEN** the user navigates to `localhost:9000` or `192.168.1.100:8080`
- **THEN** the request MUST reach the local service
- **AND** no port filtering MUST be applied

#### Scenario: Proxy access
- **WHEN** the debug browser is configured with a proxy (e.g., Squid for analysis)
- **THEN** all traffic MUST flow through the proxy
- **AND** no domain-level filtering MUST be applied at the browser level

### Requirement: DevTools and console access

Chromium DevTools MUST be enabled for debugging and inspection.

#### Scenario: DevTools opens via keyboard
- **WHEN** the user presses `F12` or `Ctrl+Shift+I`
- **THEN** the DevTools panel MUST open
- **AND** Network, Console, Elements, Application tabs MUST all be available

#### Scenario: Remote DevTools over CDP
- **WHEN** an external tool (e.g., test framework) connects to the debug browser via Chrome DevTools Protocol (CDP)
- **THEN** the connection MUST be accepted
- **AND** full protocol access MUST be available (DOM manipulation, network capture, execution)

#### Scenario: Console access
- **WHEN** the user opens the browser console (DevTools → Console)
- **THEN** full access to JavaScript console MUST be available
- **AND** the user MUST be able to execute arbitrary JavaScript in the page context
- **AND** console errors and logs MUST be visible

### Requirement: Extensions and plugins allowed

Third-party extensions and plugins MUST be enabled for testing.

#### Scenario: Extensions installable
- **WHEN** the user opens `chrome://extensions` in the debug browser
- **THEN** extensions MUST be listed and can be enabled/disabled
- **AND** the browser MUST NOT be running with `--disable-extensions`

#### Scenario: Plugin support
- **WHEN** a website attempts to load a plugin
- **THEN** the plugin MUST be allowed (if available in the container)
- **AND** no sandboxing restrictions MUST be applied

#### Scenario: Extension logging
- **WHEN** an extension logs events or errors
- **THEN** the logs MUST be visible in the DevTools console
- **AND** extension execution MUST NOT be restricted

### Requirement: Verbose network logging

All network activity MUST be logged in detailed format for traffic analysis.

#### Scenario: HAR logging
- **WHEN** the browser starts
- **THEN** a HAR (HTTP Archive) file MUST be created at `/tmp/chrome-har.json`
- **AND** all HTTP requests and responses MUST be recorded (headers, body, timing)
- **AND** the HAR file MUST be human-readable JSON

#### Scenario: Console network logs
- **WHEN** the user opens DevTools → Network tab
- **THEN** all requests MUST be listed with full details (status, size, timing, headers)
- **AND** request/response bodies MUST be inspectable

#### Scenario: Request body logging
- **WHEN** a request is made with a POST body
- **THEN** the body MUST be captured in the HAR and in DevTools
- **AND** sensitive data (passwords, API keys) MAY be visible (expected in debug mode)
- **AND** logs MUST be marked `debug_mode = true` for awareness

### Requirement: Ephemeral profile and cache

Like the safe variant, profile and cache MUST be tmpfs-backed and destroyed on shutdown.

#### Scenario: Profile in tmpfs
- **WHEN** the debug container starts
- **THEN** a new profile MUST be created in `/tmp/chrome-profile/` (tmpfs)
- **AND** the profile MUST be empty (no history, bookmarks, extensions)

#### Scenario: Extensions installed during session
- **WHEN** the user installs an extension during the session
- **THEN** the extension MUST be stored in `/tmp/chrome-profile/Extensions/`
- **AND** MUST be destroyed when the container stops

#### Scenario: Cache in tmpfs
- **WHEN** the browser caches resources
- **THEN** the cache MUST be stored in `/tmp/chrome-cache/` (tmpfs, not disk)
- **AND** MUST be destroyed on container shutdown

#### Scenario: No credential persistence
- **WHEN** the user enters a password or API key
- **THEN** it MUST NOT be saved to persistent storage
- **AND** the next session MUST NOT have auto-fill or recovery
- **AND** the user MUST re-enter credentials (or use a password manager outside the container)

### Requirement: Verbose logging to host

Debug events (DevTools connections, network requests, extension loads, crashes) MUST be logged to the host with full detail.

#### Scenario: Container logs show DevTools events
- **WHEN** a DevTools connection is established
- **THEN** the container MUST log `devtools_connection = true, client_ip = "...", timestamp = "..."`

#### Scenario: Network request logging
- **WHEN** the browser makes an HTTP request
- **THEN** the container MUST log `http_request = true, method = "GET", url = "...", status_code = 200`

#### Scenario: Extension load logging
- **WHEN** an extension is loaded
- **THEN** the container MUST log `extension_loaded = true, id = "abc123", name = "..."`

#### Scenario: Crash logging
- **WHEN** Chromium or a renderer process crashes
- **THEN** the container MUST log `crash = true, reason = "segfault"` with stack trace if available

### Requirement: Safe isolation (still ephemeral)

Despite being unrestricted, the debug browser MUST still use ephemeral storage and container isolation.

#### Scenario: Isolation from host
- **WHEN** the debug browser is running
- **THEN** it MUST NOT directly access the host filesystem (except via mounted volumes)
- **AND** the host MUST NOT see the browser's cache or profile

#### Scenario: Isolation from other containers
- **WHEN** multiple debug browsers run (different containers)
- **THEN** each MUST have its own tmpfs profile and cache
- **AND** they MUST NOT share cookies, extensions, or history

### Requirement: Litmus test — chromium-debug-variant lifecycle

Critical verification paths:

#### Test: Unrestricted domain access
```bash
# Start debug browser
podman run --rm -d --name test-debug-browser tillandsias-chromium-debug \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Test access to various domains
for domain in localhost:8000 example.com 192.168.1.1 google.com; do
  podman exec test-debug-browser timeout 5 curl -s http://$domain/ > /dev/null 2>&1 && \
    echo "✓ $domain accessible" || echo "✗ $domain failed (expected for unreachable)"
done

podman stop test-debug-browser
```

#### Test: DevTools enabled
```bash
# Start browser with DevTools protocol enabled
podman run --rm -d --name test-debug-devtools tillandsias-chromium-debug \
  chromium --user-data-dir=/tmp/chrome-profile \
           --remote-debugging-port=9222

sleep 3

# Connect to DevTools protocol
timeout 5 curl http://localhost:9222/json/version 2>&1 | grep -q "Chrome-Version"
# Expected: success (DevTools responding)

podman stop test-debug-devtools
```

#### Test: HAR logging
```bash
# Start debug browser with HAR output
podman run --rm -d --name test-debug-har tillandsias-chromium-debug \
  sh -c "chromium --user-data-dir=/tmp/chrome-profile & sleep 10"

sleep 3

# Make a request inside browser (simulated)
podman exec test-debug-har curl -s https://example.com/ > /dev/null

sleep 2

# Check for HAR file
podman exec test-debug-har test -f /tmp/chrome-har.json && \
  podman exec test-debug-har jq '.log.entries | length' /tmp/chrome-har.json
# Expected: JSON file with entry count > 0

podman stop test-debug-har
```

#### Test: Verbose logging
```bash
# Start browser
podman run --rm -d --name test-debug-logs tillandsias-chromium-debug \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Simulate network activity
podman exec test-debug-logs curl -s https://example.com/ >/dev/null

# Check container logs for request entry
podman logs test-debug-logs 2>&1 | grep -i "http_request\|network"
# Expected: log lines showing network activity (may vary by container logging setup)

podman stop test-debug-logs
```

#### Test: Ephemeral profile
```bash
# Start debug browser
podman run --rm -d --name test-debug-ephemeral tillandsias-chromium-debug \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Verify profile exists in container
podman exec test-debug-ephemeral ls -la /tmp/chrome-profile/
# Expected: directory with Chromium profile

# Stop container
podman stop test-debug-ephemeral

# Start again
podman run --rm -d --name test-debug-ephemeral tillandsias-chromium-debug \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Verify fresh profile (no history from previous session)
podman exec test-debug-ephemeral find /tmp/chrome-profile -name "History" -type f
# Expected: empty or no History file (fresh profile)

podman stop test-debug-ephemeral
```

#### Test: Extension support
```bash
# Start debug browser
podman run --rm -d --name test-debug-ext tillandsias-chromium-debug \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Check that extensions directory is accessible
podman exec test-debug-ext test -d /tmp/chrome-profile/Extensions && \
  echo "✓ Extensions directory exists"

# Verify --disable-extensions is NOT set
podman ps | grep test-debug-ext | grep -q "disable-extensions"
# Expected: no match (extensions not disabled)

podman stop test-debug-ext
```

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:chromium-debug-variant" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "chromium-debug-variant"` on all container lifecycle events
- `devtools_connection = true` when DevTools connects
- `http_request = true, method = "GET", url = "...", status_code = N` on requests
- `extension_loaded = true, id = "<id>", name = "<name>"` on extension load
- `crash = true, reason = "<reason>"` on process crash
- `har_entries = N` on HAR completion

## Sources of Truth

- `cheatsheets/runtime/chromium-headless.md` — DevTools protocol and remote debugging
- `cheatsheets/runtime/event-driven-monitoring.md` — network event capture and HAR format
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — tmpfs-backed ephemeral storage
- `cheatsheets/observability/cheatsheet-metrics.md` — structured logging for network events

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable


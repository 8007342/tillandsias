<!-- @trace spec:chromium-safe-variant -->

# chromium-safe-variant Specification

## Status

status: active

## Purpose

Ephemeral, restricted Chromium variant for production web access. Runs in a tmpfs-backed container with minimal capabilities, domain allowlist enforcement, zero credential persistence, zero cache, and zero sync. Profile and tabs are destroyed on shutdown. Designed for safe, auditable web access in development environments.

This spec ensures:
- Web browsing is confined to approved domains
- No credentials persist across sessions
- Cache is ephemeral (tmpfs)
- No sync, autofill, password manager
- Full network isolation (enclave-only or proxy-controlled)

## Requirements

### Requirement: Ephemeral profile on tmpfs

Chromium profile (bookmarks, history, preferences, extensions) MUST be stored in tmpfs, created fresh on startup, and destroyed on shutdown.

#### Scenario: Profile creation on startup
- **WHEN** a safe-variant browser container starts
- **THEN** a new Chromium user profile SHALL be created in `/tmp/chrome-profile/` (tmpfs-backed)
- **AND** the profile MUST be completely empty (no history, bookmarks, extensions)
- **AND** default preferences SHALL be applied from a read-only template

#### Scenario: Profile destruction on shutdown
- **WHEN** the container exits (graceful or crash)
- **THEN** the profile directory SHALL be deleted via tmpfs unmount
- **AND** no profile data MUST persist to the next launch
- **AND** history, cookies, and local storage MUST be completely erased

#### Scenario: No sync or cloud services
- **WHEN** Chromium starts in the safe-variant container
- **THEN** all cloud sync services (Google Account sync, Chromium Sync) MUST be disabled
- **AND** Chromium MUST NOT be logged in to any account
- **AND** no data SHALL be transmitted to external sync services

### Requirement: Domain allowlist enforcement

Only whitelisted domains MAY be accessible from the safe-variant browser.

#### Scenario: Domain allowlist configuration
- **WHEN** the container starts
- **THEN** a domain allowlist SHALL be loaded from `/opt/chromium-config/allowlist.txt` (baked into image)
- **AND** the allowlist SHALL contain FQDNs and wildcard patterns (e.g., `*.github.com`, `example.org`)
- **AND** a proxy or extension MUST enforce the allowlist

#### Scenario: Allowed domain access
- **WHEN** the user navigates to `github.com` (in allowlist)
- **THEN** the request MUST be allowed
- **AND** the page SHALL load normally

#### Scenario: Blocked domain access
- **WHEN** the user navigates to `facebook.com` (not in allowlist)
- **THEN** the browser MUST block the request with a "Not allowed" message
- **AND** MUST log `domain_blocked = true, domain = "facebook.com", reason = "not in allowlist"` with `spec = "chromium-safe-variant"`
- **AND** no request MUST reach the domain (not a server-side block)

#### Scenario: Dynamic allowlist updates
- **WHEN** a new project-specific allowlist is provided via `.tillandsias/chromium-allowlist.txt`
- **THEN** the container SHALL merge it with the default allowlist
- **AND** the browser SHALL enforce the combined set
- **AND** invalid entries SHOULD be logged as warnings

### Requirement: Credential isolation — no persistence

Credentials (cookies, passwords, autofill) MUST NOT be persisted and MUST NOT be synced.

#### Scenario: Cookies ephemeral
- **WHEN** a website sets a cookie during the session
- **THEN** the cookie SHALL be stored in memory (session storage)
- **AND** on container shutdown, the cookie MUST be destroyed
- **AND** the next browser session SHALL have no cookies (clean slate)

#### Scenario: Password manager disabled
- **WHEN** the user enters a password in a form
- **THEN** Chromium MUST NOT offer to save the password
- **AND** no password manager data MUST be stored
- **AND** the user MUST NOT be able to auto-fill credentials

#### Scenario: Autofill disabled
- **WHEN** the user types into a form field
- **THEN** Chromium MUST NOT suggest previously-entered values
- **AND** no form history MUST be persisted
- **AND** the user SHALL manually re-enter information each session

### Requirement: Cache is ephemeral and minimal

Chromium cache MUST be stored in tmpfs, limited in size, and destroyed on shutdown.

#### Scenario: Cache in tmpfs
- **WHEN** Chromium caches a web resource
- **THEN** the cache SHALL be written to `/tmp/chrome-cache/` (tmpfs, not disk)
- **AND** SHALL survive for the duration of the container
- **AND** SHALL be deleted on shutdown

#### Scenario: Cache size limit
- **WHEN** the cache reaches 500 MB (configurable)
- **THEN** Chromium MUST evict oldest entries
- **AND** MUST NOT grow beyond the limit
- **AND** SHOULD log `cache_eviction = true, reason = "size limit"`

#### Scenario: No persistent cache on reboot
- **WHEN** a browser container is destroyed and a new one starts
- **THEN** the new container SHALL have an empty cache
- **AND** SHALL re-fetch all resources

### Requirement: Minimal capabilities — cap-drop=ALL

Safe-variant container MUST run with minimum Linux capabilities required for display and network access.

#### Scenario: Capability set
- **WHEN** the container starts
- **THEN** it SHALL be launched with `--cap-drop=ALL` (no Linux capabilities)
- **AND** only capabilities explicitly needed MAY be added back (e.g., `--cap-add=NET_BIND_SERVICE` if needed for local proxies)
- **AND** most system privileges MUST be removed

#### Scenario: No privilege escalation
- **WHEN** code inside the container attempts privilege escalation
- **THEN** it MUST fail (no `CAP_SYS_ADMIN`, `CAP_SETUID`, etc.)
- **AND** SHOULD log `privilege_escalation_attempt = true` for audit

#### Scenario: Network isolation
- **WHEN** the container is not in the enclave network
- **THEN** it SHALL have only host (gateway) network access
- **OR** if in the enclave, it SHALL connect via the proxy (allowlist enforced upstream)

### Requirement: No extensions or plugins

Third-party extensions and plugins MUST NOT be allowed in the safe-variant.

#### Scenario: Extensions disabled
- **WHEN** the container starts
- **THEN** Chromium SHALL be configured with `--disable-extensions`
- **AND** even built-in extensions (if not critical) SHOULD be disabled

#### Scenario: Plugin sandboxing
- **WHEN** a website attempts to load a plugin (PPAPI)
- **THEN** the plugin MUST be blocked
- **AND** SHOULD log `plugin_blocked = true, plugin = "flash"` or similar

### Requirement: Litmus test — chromium-safe-variant lifecycle

Critical verification paths:

#### Test: Ephemeral profile
```bash
# Start safe-variant browser
podman run --rm -d --name test-safe-browser tillandsias-chromium-safe \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Verify profile exists in container
podman exec test-safe-browser ls -la /tmp/chrome-profile/
# Expected: directory with Chromium profile structure

# Verify no profile on host
ls /tmp/chrome-profile/ 2>&1
# Expected: no such file (profile only inside container)

# Stop container
podman stop test-safe-browser

# Verify profile destroyed
podman exec test-safe-browser ls -la /tmp/chrome-profile/ 2>&1
# Expected: error (container stopped)
```

#### Test: Domain allowlist enforcement
```bash
# Start browser with allowlist
podman run --rm -d --name test-safe-allowlist tillandsias-chromium-safe \
  sh -c "echo '*.example.com' > /opt/chromium-config/allowlist.txt && chromium ..."

sleep 3

# Test blocked domain
podman exec test-safe-allowlist curl -s http://blocked.com/ 2>&1 | head -5
# Expected: error or "blocked" message

# Test allowed domain
podman exec test-safe-allowlist curl -s http://example.com/ 2>&1 | head -5
# Expected: page content or successful response

podman stop test-safe-allowlist
```

#### Test: Credential ephemeral
```bash
# Start browser and simulate login
podman run --rm -d --name test-safe-creds tillandsias-chromium-safe \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Simulate setting a cookie (JavaScript or curl proxy)
podman exec test-safe-creds sh -c "echo 'test=value' > /tmp/chrome-profile/Cookies"

# Verify cookie file exists while running
podman exec test-safe-creds ls -la /tmp/chrome-profile/Cookies
# Expected: file exists

# Stop and restart container
podman stop test-safe-creds
podman run --rm -d --name test-safe-creds tillandsias-chromium-safe \
  chromium --user-data-dir=/tmp/chrome-profile

sleep 3

# Verify no old cookies
podman exec test-safe-creds ls -la /tmp/chrome-profile/Cookies 2>&1 | head -2
# Expected: no such file (new profile)

podman stop test-safe-creds
```

#### Test: Minimal capabilities
```bash
# Start browser
podman run --rm -d --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --name test-safe-caps tillandsias-chromium-safe chromium

sleep 3

# Check capabilities
podman exec test-safe-caps grep -i ^cap /proc/1/status
# Expected: CapEff and CapPrm show minimal set (not all 0s)

# Attempt privilege escalation (should fail)
podman exec test-safe-caps sudo su 2>&1
# Expected: error (sudo not available, no CAP_SETUID)

podman stop test-safe-caps
```

#### Test: Cache in tmpfs
```bash
# Start browser
podman run --rm -d --name test-safe-cache tillandsias-chromium-safe \
  chromium --cache-dir=/tmp/chrome-cache

sleep 3

# Fetch a resource (will be cached)
podman exec test-safe-cache curl -s https://example.com/logo.png > /dev/null

sleep 1

# Verify cache directory exists in tmpfs
podman exec test-safe-cache du -sh /tmp/chrome-cache/
# Expected: output showing cache size > 0

# Stop container
podman stop test-safe-cache

# Verify cache destroyed
podman exec test-safe-cache du -sh /tmp/chrome-cache/ 2>&1
# Expected: error (container stopped)
```

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:browser-ephemeral`

Gating points:
- Profile and cache are ephemeral (tmpfs), destroyed on shutdown; credentials never persist; domain allowlist is enforced
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:chromium-safe-variant" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "chromium-safe-variant"` on all container lifecycle events
- `domain_blocked = true, domain = "<fqdn>"` when request is blocked
- `cache_eviction = true, reason = "<reason>"` on cache size events
- `privilege_escalation_attempt = true` on security violations
- `profile_destroyed = true` on container shutdown

## Sources of Truth

- `cheatsheets/runtime/chromium-isolation.md` — sandboxing and capability isolation patterns
- `cheatsheets/runtime/chromium-seccomp.md` — syscall filtering and container constraints
- `cheatsheets/security/owasp-top-10-2021.md` — credential protection (A02:2021)
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — tmpfs-backed profile layout


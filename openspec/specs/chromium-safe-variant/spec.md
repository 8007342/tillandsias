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

The Chromium profile (bookmarks, history, preferences, extensions) is stored in tmpfs, created fresh on startup, and destroyed on shutdown.

#### Scenario: Profile creation on startup
- **WHEN** a safe-variant browser container starts
- **THEN** a new Chromium user profile is created in `/tmp/chrome-profile/` (tmpfs-backed)
- **AND** the profile is completely empty (no history, bookmarks, extensions)
- **AND** default preferences are applied from a read-only template

#### Scenario: Profile destruction on shutdown
- **WHEN** the container exits (graceful or crash)
- **THEN** the profile directory is deleted via tmpfs unmount
- **AND** no profile data persists to the next launch
- **AND** history, cookies, and local storage are completely erased

#### Scenario: No sync or cloud services
- **WHEN** Chromium starts in the safe-variant container
- **THEN** all cloud sync services (Google Account sync, Chromium Sync) are disabled
- **AND** Chromium is not logged in to any account
- **AND** no data is transmitted to external sync services

### Requirement: Domain allowlist enforcement

Only whitelisted domains are accessible from the safe-variant browser.

#### Scenario: Domain allowlist configuration
- **WHEN** the container starts
- **THEN** a domain allowlist is loaded from `/opt/chromium-config/allowlist.txt` (baked into image)
- **AND** the allowlist contains FQDNs and wildcard patterns (e.g., `*.github.com`, `example.org`)
- **AND** a proxy or extension enforces the allowlist

#### Scenario: Allowed domain access
- **WHEN** the user navigates to `github.com` (in allowlist)
- **THEN** the request is allowed
- **AND** the page loads normally

#### Scenario: Blocked domain access
- **WHEN** the user navigates to `facebook.com` (not in allowlist)
- **THEN** the browser blocks the request with a "Not allowed" message
- **AND** logs `domain_blocked = true, domain = "facebook.com", reason = "not in allowlist"` with `spec = "chromium-safe-variant"`
- **AND** no request reaches the domain (not a server-side block)

#### Scenario: Dynamic allowlist updates
- **WHEN** a new project-specific allowlist is provided via `.tillandsias/chromium-allowlist.txt`
- **THEN** the container merges it with the default allowlist
- **AND** the browser enforces the combined set
- **AND** invalid entries are logged as warnings

### Requirement: Credential isolation — no persistence

Credentials (cookies, passwords, autofill) are NOT persisted and NOT synced.

#### Scenario: Cookies ephemeral
- **WHEN** a website sets a cookie during the session
- **THEN** the cookie is stored in memory (session storage)
- **AND** on container shutdown, the cookie is destroyed
- **AND** the next browser session has no cookies (clean slate)

#### Scenario: Password manager disabled
- **WHEN** the user enters a password in a form
- **THEN** Chromium does NOT offer to save the password
- **AND** no password manager data is stored
- **AND** the user cannot auto-fill credentials

#### Scenario: Autofill disabled
- **WHEN** the user types into a form field
- **THEN** Chromium does NOT suggest previously-entered values
- **AND** no form history is persisted
- **AND** the user must manually re-enter information each session

### Requirement: Cache is ephemeral and minimal

The Chromium cache is stored in tmpfs, limited in size, and destroyed on shutdown.

#### Scenario: Cache in tmpfs
- **WHEN** Chromium caches a web resource
- **THEN** the cache is written to `/tmp/chrome-cache/` (tmpfs, not disk)
- **AND** survives for the duration of the container
- **AND** is deleted on shutdown

#### Scenario: Cache size limit
- **WHEN** the cache reaches 500 MB (configurable)
- **THEN** Chromium evicts oldest entries
- **AND** does not grow beyond the limit
- **AND** logs `cache_eviction = true, reason = "size limit"`

#### Scenario: No persistent cache on reboot
- **WHEN** a browser container is destroyed and a new one starts
- **THEN** the new container has an empty cache
- **AND** must re-fetch all resources

### Requirement: Minimal capabilities — cap-drop=ALL

The safe-variant container runs with the minimum Linux capabilities required for display and network access.

#### Scenario: Capability set
- **WHEN** the container starts
- **THEN** it is launched with `--cap-drop=ALL` (no Linux capabilities)
- **AND** only capabilities explicitly needed are added back (e.g., `--cap-add=NET_BIND_SERVICE` if needed for local proxies)
- **AND** most system privileges are removed

#### Scenario: No privilege escalation
- **WHEN** code inside the container attempts privilege escalation
- **THEN** it fails (no `CAP_SYS_ADMIN`, `CAP_SETUID`, etc.)
- **AND** logs `privilege_escalation_attempt = true` for audit

#### Scenario: Network isolation
- **WHEN** the container is not in the enclave network
- **THEN** it has only host (gateway) network access
- **OR** if in the enclave, it connects via the proxy (allowlist enforced upstream)

### Requirement: No extensions or plugins

Third-party extensions and plugins are not allowed in the safe-variant.

#### Scenario: Extensions disabled
- **WHEN** the container starts
- **THEN** Chromium is configured with `--disable-extensions`
- **AND** even built-in extensions (if not critical) are disabled

#### Scenario: Plugin sandboxing
- **WHEN** a website attempts to load a plugin (PPAPI)
- **THEN** the plugin is blocked
- **AND** logs `plugin_blocked = true, plugin = "flash"` or similar

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


<!-- @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy -->

# Browser Routing and Allowlist Infrastructure Design

**Date**: 2026-05-14  
**Task**: browser/routing-allowlist (Wave 2c)  
**Prerequisite Complete**: browser/session-otp (Wave 2b)  
**Next Task**: implementation work identified at end

## Executive Summary

This document outlines the infrastructure design for browser routing and allowlists in Tillandsias. The design centers on:

1. **Caddy reverse-proxy** as the centralized router for all `<service>.<project>.localhost` URLs
2. **Forward-proxy integration** so forge agents can reach the reverse-proxy through the existing Squid forward proxy
3. **Dynamic allowlist generation** driven by active window registry and OTP session state
4. **Ephemeral Caddyfile generation** with admin API reloads to avoid container restarts

The design converges toward three key properties:
- **No host-side port publication**: All forge services bind internally; the router is the sole host-side listener on port 80
- **RFC 6761 loopback binding**: `*.localhost` routes stay on `127.0.0.1` and never leak externally
- **Session-gated URLs**: Browser allowlists key off active OTP sessions (one per window), not project names

---

## Naming Convention: `<service>.<project>.localhost`

### Requirement: Subdomain Ordering Inversion

Per `spec:subdomain-naming-flip`, all URLs follow the pattern **`<service>.<project>.localhost`** (service first).

| Pattern | Example | Status |
|---------|---------|--------|
| `<service>.<project>.localhost` | `opencode.java.localhost` | ✅ **REQUIRED** |
| `<project>.<service>.localhost` | `java.opencode.localhost` | ❌ OBSOLETE |
| `*.project.localhost` | `*.java.localhost` | ✅ Wildcard for allowlists |

### Naming Constraints

- **Project names**: Must match the container naming scheme `tillandsias-<project>-<genus>`. Extracted from `state.rs` window registry.
- **Service names**: Pre-defined per `spec:subdomain-routing-via-reverse-proxy`:
  - `opencode` → port 4096 (OpenCode Web)
  - `flutter` → port 8080 (Flutter dev server)
  - `vite`, `next`, `webpack`, `jupyter`, `streamlit` → standard ports
- **Localhost TLD**: Always `.localhost` (no `.test`, `.local`, etc.). RFC 6761 guarantees loopback resolution.

### Allowlist Implications

Browser MCP allowlists simplify to **hierarchical wildcards**:
- Allow: `*.project.localhost:80` (all services under a project)
- Allow: `*.*.localhost:80` (all services under any active project)
- Except: Specific denials (e.g., `opencode.*.localhost` if policy demands it)

---

## Proxy Architecture: Three Containers

The enclave has **three network containers**, layered for security and routing:

### 1. Forward Proxy (Squid, `tillandsias-proxy`)

**Role**: Boundary guard for external egress. Runs on port 3128 (strict allowlist).

**Key behavior**:
- Forge containers send all HTTP(S) requests through `HTTP_PROXY=http://proxy:3128`
- Squid **peeks at SNI** in TLS ClientHello to read the hostname, then **splices** (tunnels) without decryption
- Domain allowlist (`allowlist.txt`) blocks unauthorized external domains → HTTP 403
- **New behavior**: `.localhost` hostnames are forwarded to the reverse-proxy sibling at `router:80`

**Config change for localhost forwarding**:
```squid
acl localhost_subdomain dstdomain .localhost
cache_peer router parent 80 0
cache_peer_access router allow localhost_subdomain
never_direct allow localhost_subdomain
```

This lets agents reach enclave-local services: `curl http://opencode.java.localhost/` goes through `proxy:3128` → `router:80` → `tillandsias-java-forge:4096`.

### 2. Reverse-Proxy (Caddy, `tillandsias-router`)

**Role**: Internal router for all `*.localhost` URLs. Runs on port 8080 (loopback only, per base.Caddyfile).

**Architecture**:
- **Host binding**: `127.0.0.1:8080` only (no external access possible)
- **Enclave binding**: Accessible at `router:8080` on `tillandsias-enclave` network
- **Config layers**:
  - **Base config**: `images/router/base.Caddyfile` (static, baked into image) — defines admin API, storage, defence-in-depth ACLs
  - **Dynamic routes**: Generated at `$XDG_RUNTIME_DIR/tillandsias/router/dynamic.Caddyfile` by tray at attach time
  - **Merge**: Entrypoint merges base + dynamic before exec'ing `caddy run`
  - **Config reload**: `caddy reload` command via admin API (`http://localhost:2019/reload`) — no container restart
- **Session validation**: `tillandsias-router-sidecar` binary runs inside the container and:
  - Subscribes to tray's control socket for OTP session events
  - Serves Caddy's `forward_auth` directive on `127.0.0.1:9090` (within container)
  - Validates cookies by checking the in-memory OTP store before allowing requests through

**Sample dynamic.Caddyfile**:
```
opencode.java.localhost:8080 {
  forward_auth 127.0.0.1:9090 /validate
  reverse_proxy tillandsias-java-forge:4096
}

flutter.java.localhost:8080 {
  reverse_proxy tillandsias-java-forge:8080
}

opencode.python.localhost:8080 {
  forward_auth 127.0.0.1:9090 /validate
  reverse_proxy tillandsias-python-forge:4096
}
```

**Dynamic updates**:
- Every time a forge attaches, the tray regenerates the dynamic.Caddyfile with all active service routes
- Every time a window closes, the corresponding routes are removed from the dynamic.Caddyfile
- Tray calls `caddy reload` via admin API (localhost-only, no TLS needed)
- Reload is **sub-millisecond** — no container lifecycle events
- The router-sidecar's session store is NOT cleared on reload (persistent across config changes)

### 3. Git Service and Inference (Enclave-local, non-router)

These are **not** routed through the reverse-proxy:
- **Git**: Accessed directly at `git:9418` (git protocol)
- **Inference**: Accessed directly at `inference:11434` (ollama HTTP)

They live on the `tillandsias-enclave` network and do NOT bind to host ports.

---

## State Machine: Window Registry Drives Routing

### Input: Browser Window Registry

`crates/tillandsias-core/src/state.rs` maintains a **window registry**:
```rust
pub struct WindowRegistry {
    pub windows: HashMap<WindowId, BrowserWindow>,
}

pub struct BrowserWindow {
    pub id: WindowId,
    pub project: String,      // e.g., "java"
    pub service: String,      // e.g., "opencode"
    pub otp_session: SessionToken,  // Issued by router-sidecar via control socket
    pub url: String,          // e.g., "http://opencode.java.localhost:8080/"
    pub container_name: String, // e.g., "tillandsias-java-aeranthos" (includes genus)
}
```

### Processing: Derive Routes from Registry

When the registry changes, the tray calls `regenerate_dynamic_caddyfile()`:

```rust
fn regenerate_dynamic_caddyfile(registry: &WindowRegistry) -> String {
    let mut lines = vec![];
    
    for (window_id, window) in &registry.windows {
        let hostname = format!("{}.{}.localhost", window.service, window.project);
        let port = service_to_port(&window.service);
        
        // @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
        if window.service == "opencode" {
            // OpenCode Web requires session validation via forward_auth
            lines.push(format!(
                "{hostname}:8080 {{\n  forward_auth 127.0.0.1:9090 /validate?project={project}\n  reverse_proxy {container}:{port}\n}}",
                hostname = hostname,
                project = window.project,
                container = window.container_name,
                port = port
            ));
        } else {
            // Other services (flutter, vite, etc.) don't require auth
            lines.push(format!(
                "{hostname}:8080 {{\n  reverse_proxy {container}:{port}\n}}",
                hostname = hostname,
                container = window.container_name,
                port = port
            ));
        }
    }
    
    lines.join("\n\n")
}
```

### Output: Caddyfile at `$XDG_RUNTIME_DIR/tillandsias/router/dynamic.Caddyfile`

Generated on every window registry mutation. Tray calls `caddy reload` via admin API to activate the new config live.

---

## Allowlist Security Model

### Browser-Side Allowlist (Host MCP)

Per `spec:host-browser-mcp`, the browser MCP enforces **destination-based allowlist** on outbound navigation:

**Allowed destinations**:
- `http://*.localhost:80/` — Any service under any active project
- `https://*.localhost:443/` — HTTPS variant (if router upgrades to TLS)
- Optionally: Localhost variants with `127.0.0.1` direct IPs (fallback)

**Denied destinations**:
- Any external domains (e.g., `google.com`, `github.com`)
- `localhost:8080` or non-standard ports (not routed through reverse-proxy)
- `127.0.0.1:8080` direct container port access (bypasses router security gate)

**Mechanism**:
- Browser MCP intercepts `chrome.webRequest.onBeforeRequest`
- Blocks requests if destination is not in the allowlist
- Logs denials to `--log-browser-mcp` for troubleshooting

### Forward-Proxy Allowlist (Squid)

Squid's existing `allowlist.txt` already blocks unauthorized external egress. No new logic needed here, but Squid **must recognize `.localhost` as enclave-internal** and forward to the router peer.

### Session-Gating (OpenCode Web OTP)

Per `spec:opencode-web-session-otp`, the OpenCode Web service **gates initial access with a one-time password (OTP)**. The allowlist does NOT gate sessions; instead:

1. User clicks "🌐 OpenCode Web" in the tray
2. Browser is launched with the URL `http://opencode.project.localhost/`
3. The browser reaches the reverse-proxy, which forwards to `tillandsias-project-forge:4096`
4. OpenCode Web service returns HTTP 401 or a login page until the OTP is verified
5. Once verified, the browser receives a session cookie (valid for the browser's lifetime)

**No changes to the allowlist logic are needed** — the OTP gate is a service-level concern, not a network-level one.

---

## Data Flow: From Browser to Service

### Scenario: User Clicks "OpenCode Web"

```
1. User clicks "🌐 OpenCode Web" in tray
2. Tray issues an OTP session via control socket → router-sidecar:
   a. Tray sends ControlEnvelope::IssueWebSession(project="java", cookie="sess_abc123")
   b. Router-sidecar stores it in OTP store (24h client-side Max-Age)
3. Tray spawns browser container with:
   - URL: http://opencode.java.localhost:8080/
   - Image: tillandsias-chromium-framework:v<VERSION>
   - Bind-mount: ephemeral CA chain (/run/tillandsias/ca-chain.crt)
   - Capsule: --cap-drop=ALL --userns=keep-id
   - Cookie: Set-Cookie: tillandsias-session=sess_abc123 (via tray)

4. Browser makes GET request with session cookie:
   GET http://opencode.java.localhost:8080/ HTTP/1.1
   Cookie: tillandsias-session=sess_abc123

5. Browser → Forward Proxy (Squid):
   a. Browser sends CONNECT request to proxy:3128
   b. Squid recognizes .localhost TLD (dstdomain .localhost)
   c. Squid forwards to cache_peer router:8080
   d. Squid NEVER attempts external DNS for .localhost

6. Reverse-Proxy (Caddy):
   a. Receives request at router:8080
   b. Matches hostname "opencode.java.localhost" in dynamic.Caddyfile
   c. BEFORE forwarding, calls `forward_auth 127.0.0.1:9090 /validate?project=java`
   d. Router-sidecar receives the forwarded request with cookie header
   e. Sidecar checks: is cookie "sess_abc123" in the OTP store for "java"?
   f. If yes: sidecar returns HTTP 204 (OK); Caddy proceeds to reverse_proxy
   g. If no: sidecar returns HTTP 401 (Unauthorized); Caddy blocks the request

7. Caddy forwards to OpenCode Web (only if session is valid):
   a. Forwards request to tillandsias-java-forge:4096
   b. OpenCode Web receives authenticated request
   c. Returns HTTP 200 with content (no OTP dialog needed)

8. Browser displays OpenCode Web UI
9. User works in OpenCode Web
10. Browser window closes or user detaches:
    a. Tray removes window from registry
    b. Dynamic.Caddyfile is regenerated (without the opencode.java.localhost route)
    c. Caddy reloads with `caddy reload`
    d. OTP store entry expires after 24h client-side Max-Age
```

### Scenario: Forge Agent Self-Tests

```
# Inside forge container:
curl http://opencode.java.localhost/api/status

1. curl sends request to HTTP_PROXY=http://proxy:3128
2. Squid recognizes .localhost → forwards to router:80
3. Reverse-proxy matches and forwards to tillandsias-java-forge:4096
4. OpenCode Web responds to the agent
5. Agent logs response to stdout
```

---

## State Mutations: Registry ↔ Router

### Mutation 1: Window Opens

**When**: Browser is launched (user clicks "🌐 OpenCode Web").

**Flow**:
1. `handlers::attach_browser()` creates a window in the registry
2. Registry mutation triggers `handlers::on_window_registry_changed()`
3. `on_window_registry_changed()` calls `regenerate_router_caddyfile()`
4. New Caddyfile is written to `$XDG_RUNTIME_DIR/tillandsias/router/Caddyfile`
5. Tray POSTs the new Caddyfile to Caddy admin API: `POST http://proxy:2019/config/`
6. Caddy reloads live (no restart)
7. Router is now forwarding requests to the new window's service port
8. Browser makes its first request to `http://opencode.project.localhost/`

**File mutation**: `state.rs` → window registry entry added

### Mutation 2: Window Closes

**When**: Browser window is closed or user detaches.

**Flow**:
1. Browser container exits (or is killed with `podman kill`)
2. Tray detects container stop event (podman event stream or polling)
3. `handlers::on_browser_exit()` removes the window from the registry
4. Registry mutation triggers `on_window_registry_changed()` again
5. New Caddyfile is regenerated (without the closed window's routes)
6. Caddyfile is POSTed to Caddy admin API
7. Any stale requests to the closed window's URL get HTTP 503 (service unavailable)

**File mutation**: `state.rs` → window registry entry deleted

### Mutation 3: Forge Attachment (Before Browser Launch)

**When**: User attaches to a project (e.g., `tillandsias attach ./my-project`).

**Flow**:
1. Forge container is created with a random genus name (e.g., `tillandsias-java-aeranthos`)
2. Git mirror is cloned
3. Inference container is started (if configured)
4. Reverse-proxy is already running (shared across projects)
5. Tray reads the project name and genus, then awaits browser launch
6. ← **Browser window creation happens separately (step above)**

**No immediate router mutation**: The forge is running, but no routes exist until a browser window is launched.

---

## Integration Points: Dependencies on Other Specs

### `spec:proxy-container` (Forward Proxy)

**Dependency**: The reverse-proxy relies on Squid to forward `.localhost` traffic.

**Required change in `images/proxy/squid.conf`**:
```squid
# Forward .localhost traffic to the reverse-proxy peer
acl localhost_subdomain dstdomain .localhost
cache_peer router parent 80 0
cache_peer_access router allow localhost_subdomain
never_direct allow localhost_subdomain
```

**Current state**: Squid config is static and deployed at image build time. No runtime allowlist mutations needed.

**Future enhancement**: If URL patterns become more dynamic (e.g., per-user namespaces), Squid's allowlist may need dynamic reload via `squid -k reconfigure`. Not required for current design.

### `spec:subdomain-naming-flip`

**Dependency**: Caddyfile generation must use `<service>.<project>.localhost` format.

**Implementation**: In `handlers::regenerate_router_caddyfile()`, build hostnames as:
```rust
format!("{}.{}.localhost", service, project)
```

**Validation**: Hostname must match RFC 1035 DNS label rules (alphanumeric + hyphen, no leading/trailing hyphen).

### `spec:opencode-web-session-otp`

**Dependency**: Browser allowlist does NOT gate sessions; OTP is service-level.

**Implementation**: No changes to routing layer. OpenCode Web container handles OTP verification internally.

**Coordination**: Tray must pass the ephemeral CA chain to the browser container so it can trust the reverse-proxy's HTTPS certificates (if TLS is added in future).

### `spec:browser-isolation-tray-integration`

**Dependency**: Tray code must call `regenerate_router_caddyfile()` whenever the window registry changes.

**Implementation**: Hook in `handlers::on_window_registry_changed()` (event-driven).

**Files affected**:
- `crates/tillandsias-headless/src/main.rs` — Main tray loop
- `crates/tillandsias-core/src/state.rs` — Window registry and mutation handling

### `spec:reverse-proxy-internal`

**Status**: Already specified. No new work needed; this design *implements* that spec.

---

## Potential Security Gaps and Mitigations

### Gap 0: Port Mismatch — router:80 vs router:8080

**Risk**: Inconsistency between proxy-container spec (says `router:80`) and actual base.Caddyfile (uses `:8080`).

**Current state**: 
- `openspec/specs/proxy-container/spec.md` line 317: `cache_peer router parent 80 0`
- `images/router/base.Caddyfile` line 36: `:8080 {`
- `images/router/base.Caddyfile` line 10: `-p 127.0.0.1:8080:8080`

**Action required**: 
- Either: Update proxy-container spec to reference `:8080` (correct the specification)
- Or: Update base.Caddyfile to use `:80` (correct the implementation)

**Recommendation**: Change proxy-container spec to `:8080` (matches current implementation). The base.Caddyfile is already deployed and working; changing it would require rebuilding the router image. The spec should match the implementation, not vice versa.

**Mitigation in design**: My design uses `:8080` throughout (matches actual base.Caddyfile). Wave 3 implementation should use `:8080` for Squid cache_peer and port mappings.

### Gap 1: DNS Rebinding Attack

**Risk**: Attacker registers a domain that resolves to `127.0.0.1`, then tricks browser into accessing it.

**Mitigation**: The reverse-proxy only accepts requests to `*.localhost` hostnames (per RFC 6761). Caddy rejects any other hostname with HTTP 400.

```rust
// In Caddyfile validation
if !hostname.ends_with(".localhost") {
    return Err("Hostname must end in .localhost");
}
```

### Gap 2: Container Port Escape

**Risk**: Forge service accidentally publishes a port to the host (e.g., `podman run -p 8080:8080`).

**Mitigation**: The tray's container launch code **never passes `-p` flags**. All internal service ports are bound to `0.0.0.0` inside the container, unreachable from the host without the router.

**Validation**: In CI, inspect a running forge with `podman inspect tillandsias-<project>-<genus>` and verify `PortBindings` is null or empty.

### Gap 3: Router Compromise

**Risk**: Attacker modifies the Caddyfile to redirect routes.

**Mitigation**:
- Caddyfile is ephemeral (tmpfs in `$XDG_RUNTIME_DIR`, destroyed on logout)
- Caddyfile is generated from in-memory window registry, not read from disk
- Caddy admin API is only accessible from the host (internal network), not from containers
- Caddy process runs inside a container with `--cap-drop=ALL` (no privilege escalation)

### Gap 4: Session Hijacking (Cookies)

**Risk**: Attacker steals browser session cookie and reuses it.

**Mitigation**: This is handled by `spec:opencode-web-session-otp`:
- Session cookies are issued only after OTP verification
- OTP is a one-time token (not replayable)
- Session cookies are scoped to the browser window's lifespan (destroyed on exit)
- Browser MCP should set cookie `HttpOnly` flag to prevent JavaScript access

**Future**: Consider adding `Secure` flag and `SameSite=Strict` if HTTPS is enabled.

---

## Implementation Dependencies and Next Tasks (Wave 3)

### Already Implemented (for reference)

These components are **already complete** and have traces in the codebase:

1. **Router-sidecar** (`crates/tillandsias-router-sidecar/`) — Subscribes to control socket, validates OTP sessions via `forward_auth`
2. **Base Caddyfile** (`images/router/base.Caddyfile`) — Static config with admin API, ACLs, catchall handler
3. **Subdomain naming** — Already using `<service>.<project>.localhost` format in router-sidecar code

### Task 1: Window Registry Mutation Hooks

**Depends on**: browser/launcher-contract (Wave 2a) — completed

**Status**: PARTIALLY DONE. Router-sidecar exists but tray doesn't wire its mutations to Caddyfile generation.

**Files to modify**:
- `crates/tillandsias-core/src/state.rs` — Ensure WindowRegistry has `on_registry_changed()` event hook
- `crates/tillandsias-headless/src/handlers.rs` — Add `regenerate_dynamic_caddyfile()` function (rewrite of existing window registration logic)
- `crates/tillandsias-headless/src/main.rs` — Call `on_registry_changed()` after window create/delete

**Implementation detail**: The window registry must track:
- `container_name` (e.g., `tillandsias-java-aeranthos`) — the genus name from forge attachment
- `project` (e.g., `java`) — extracted from container_name
- `service` (e.g., `opencode`) — which dev server is being exposed
- `otp_session` (e.g., `SessionToken("sess_abc123")`) — issued by router-sidecar

**Deliverable**: Window registry mutations trigger dynamic.Caddyfile regeneration.

### Task 2: Dynamic Caddyfile Generation and Caddy Reload

**Depends on**: Task 1 above

**Status**: NOT STARTED. Need to write Caddyfile generator that calls Caddy admin API.

**Files to create/modify**:
- `crates/tillandsias-core/src/caddy_config.rs` (new) — Caddyfile builder + validation
- `crates/tillandsias-headless/src/handlers.rs` — Add `reload_caddy_routes()` function

**Implementation**:
- Build dynamic.Caddyfile string from window registry (see code example in "State Machine" section above)
- Validate hostnames (must end in `.localhost`)
- Validate port numbers (must be valid service ports per the table in spec:subdomain-routing-via-reverse-proxy)
- Validate service name (must be in the pre-defined service list)
- Write to `$XDG_RUNTIME_DIR/tillandsias/router/dynamic.Caddyfile`
- Call `caddy reload` via admin API (or `caddy reload` command inside the container)
- Handle errors (HTTP 503 = service unavailable during reload; retry with exponential backoff)

**Deliverable**: Dynamic route updates without container restarts.

### Task 3: Browser Allowlist Enforcement (Browser MCP)

**Depends on**: browser/cdp-bridge (Wave 2a, in progress)

**Status**: DESIGN ONLY. No code yet.

**Files to modify**:
- `crates/tillandsias-browser-mcp/src/server.rs` — Add URL validation in `webRequest.onBeforeRequest`

**Implementation**:
- Parse destination URL from browser request event
- Match against allowlist:
  - Allow: `http://*.localhost:8080/` (any service under any active project, plain HTTP)
  - Allow: `https://*.localhost:8443/` (if HTTPS enabled in future)
  - Deny: Everything else (external domains, non-standard ports, direct IPs)
- Block if not in allowlist (return `{cancel: true}`)
- Log blocked requests to `--log-browser-mcp` for debugging

**Note**: The router's session validation (forward_auth) is **orthogonal** to browser allowlist enforcement. The browser allowlist is defense-in-depth; it prevents navigation attempts at the application layer. The router's forward_auth is network-layer gating.

**Deliverable**: Browser cannot navigate to unauthorized destinations.

### Task 4: Forward-Proxy Integration (Squid Configuration)

**Depends on**: proxy-container (already complete)

**Status**: DESIGN ONLY. Need to add `.localhost` routing to Squid config.

**Files to modify**:
- `images/proxy/squid.conf` — Add `cache_peer` and ACL rules for `.localhost`

**Implementation**:
```squid
acl localhost_subdomain dstdomain .localhost
cache_peer router parent 8080 0
cache_peer_access router allow localhost_subdomain
never_direct allow localhost_subdomain
```

- Build proxy image via `build-image.sh proxy` (triggers `flake.nix` build)
- Test with: `curl -x http://proxy:3128 http://opencode.java.localhost:8080/` from within forge

**Deliverable**: Squid forwards `.localhost` traffic to the reverse-proxy.

### Task 5: Caddy Container Lifecycle (ensure_router_running)

**Depends on**: proxy-container (already complete)

**Status**: ✅ COMPLETE (commit 96950743, Wave 1c of podman-idiomatic step)

**Files modified** (completed):
- `crates/tillandsias-headless/src/main.rs` — Added `ensure_router_running()` and `build_router_run_args()`

**Implementation** (completed):
- `ensure_router_running()`: Checks if `tillandsias-router` container is running; starts if missing
  - Image: `tillandsias-router:v<VERSION>` (built by `build-image.sh router` in flake.nix)
  - Network: `--network=tillandsias-enclave --network=bridge` (dual-homed)
  - Port: `-p 127.0.0.1:8080:8080` (loopback only, matches base.Caddyfile)
  - Alias: `--network-alias=router` (on enclave network so Squid can reach it)
  - Mounts: Control socket and config directory
  - Security flags: `--cap-drop=ALL --userns=keep-id --security-opt=no-new-privileges --rm`
  - Logging: `@trace spec:reverse-proxy-internal` annotations added
- `build_router_run_args()`: Constructs typed podman run argument list
- Health verification: Post-launch health check via admin API

**Deliverable**: Router container lifecycle management (completed; integration into OpenCode Web launch pending).

### Task 6: Router Sidecar Control Socket Integration

**Depends on**: Task 1 (Window Registry) + browser/session-otp (Wave 2b)

**Status**: ROUTER-SIDECAR CODE EXISTS (crates/tillandsias-router-sidecar/). Need to wire tray ↔ sidecar handshake.

**Files to modify**:
- `crates/tillandsias-core/src/control_socket.rs` (or similar) — Wire OTP session issuance to control socket
- `crates/tillandsias-headless/src/handlers.rs` — Call `issue_web_session()` when browser is launched

**Implementation**:
- When user clicks "🌐 OpenCode Web":
  1. Tray generates a one-time password (via `tillandsias-otp` crate)
  2. Tray sends `ControlEnvelope::IssueWebSession { project: "java", otp_token: "..." }` to control socket
  3. Router-sidecar receives it and stores in OTP store
  4. Tray spawns browser with cookie `tillandsias-session=<otp_token>`
  5. Browser makes request; Caddy's forward_auth validates cookie against sidecar's store
- Verify: Inspect router-sidecar logs, check HTTP /validate endpoint responses

**Deliverable**: Session issuance and validation are wired end-to-end.

---

## Testing and Validation

### Unit Test: Caddyfile Generation

```rust
#[test]
fn test_caddyfile_generation() {
    let mut registry = WindowRegistry::new();
    registry.add_window(WindowId(1), BrowserWindow {
        project: "java".to_string(),
        service: "opencode".to_string(),
        ..default()
    });
    
    let caddyfile = regenerate_router_caddyfile(&registry);
    assert!(caddyfile.contains("opencode.java.localhost:80"));
    assert!(caddyfile.contains("tillandsias-java-forge:4096"));
}
```

### Litmus Test: End-to-End Browser Request

```bash
#!/bin/bash
set -e

# Start enclave (proxy, router, forge)
tillandsias attach ./test-project

# Verify router is running
podman ps | grep tillandsias-router || exit 1

# Verify router is listening on loopback
netstat -tulnp | grep 127.0.0.1:80 || exit 1

# Verify Caddyfile was generated
[ -f "$XDG_RUNTIME_DIR/tillandsias/router/Caddyfile" ] || exit 1

# Verify Caddy config is valid
curl -s http://proxy:2019/config/ | jq . >/dev/null || exit 1

# Verify route exists
curl -s http://proxy:2019/config/ | grep "opencode.test-project.localhost" || exit 1

# From inside forge, verify request reaches reverse-proxy
podman exec tillandsias-test-project-genus bash -c 'curl http://opencode.test-project.localhost/' 2>&1 | grep -q "connection refused\|not found" || exit 1

echo "✅ All browser routing tests passed"
```

---

## Summary of Design Decisions

| Decision | Rationale | Alternative Considered |
|----------|-----------|------------------------|
| Caddy for reverse-proxy | Lightweight, admin API for live reload, Go-based (portable) | nginx (no admin API reload), HAProxy (complex config) |
| Dynamic Caddyfile on tmpfs | Ephemeral-first, no disk pollution | Baked config with environment substitution (less flexible) |
| Squid cache_peer for `.localhost` | Squid already in use; minimal config change | Teach Squid about enclave routing (more invasive) |
| Service-port mapping (table) | Type-safe, pre-defined, no discovery | Dynamic port discovery via env (adds complexity) |
| Browser MCP allowlist enforcement | Defense-in-depth; two layers (network + app) | Rely only on network-level allowlist (single point of failure) |
| Session cookies at service layer, not router | Clean separation of concerns; OTP gating is business logic | Route-based session enforcement (couples routing to auth) |

---

## Related Documents

- `openspec/specs/subdomain-naming-flip/spec.md` — Naming convention and rationale
- `openspec/specs/subdomain-routing-via-reverse-proxy/spec.md` — Reverse-proxy requirements and scenarios
- `openspec/specs/proxy-container/spec.md` — Forward-proxy allowlist and Squid configuration
- `openspec/specs/browser-isolation-tray-integration/spec.md` — Tray integration and browser lifecycle
- `openspec/specs/opencode-web-session-otp/spec.md` — OTP gating and session management
- `openspec/specs/host-browser-mcp/spec.md` — Browser MCP allowlist enforcement
- `cheatsheets/runtime/caddy-reverse-proxy.md` — Caddy configuration reference
- `cheatsheets/runtime/networking.md` — Enclave networking patterns

---

## Approval Sign-Off

- **Design review**: Pending
- **Security review**: Pending (focus on DNS rebinding and container port escape)
- **Integration review**: Pending (verify Squid + Caddy coordination)

---

## Wave 3 Prioritization: Recommended Task Order

Based on dependency analysis, **implement in this order**:

1. **Task 5**: Caddy container lifecycle (ensure_router_running) — **lowest dependency**, unblocks all other tasks
2. **Task 1**: Window registry mutation hooks — **enables routing pipeline**, depended on by Tasks 2 and 6
3. **Task 2**: Dynamic Caddyfile generation and Caddy reload — **core routing logic**, depended on by browser to work
4. **Task 6**: Router-sidecar control socket integration — **session validation**, coordinated with Task 2
5. **Task 4**: Squid forward-proxy integration — **enclave networking**, mostly config, low risk
6. **Task 3**: Browser MCP allowlist enforcement — **defense-in-depth**, can land after tasks 1–4 prove routing works

---

**Document status**: DRAFT  
**Next step**: Execute Wave 3 tasks in recommended order above  
**Wave 3 owner**: Dedicated agent(s) for routing + allowlist implementation

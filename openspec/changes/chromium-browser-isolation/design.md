## Context

Tillandsias currently has no hardened browser isolation layer. The tray app either relies on the OS-native browser (security responsibility delegated to the OS) or embeds a Tauri webview (tied to the tray process lifecycle). Both approaches:
1. Expose host credentials if the browser is compromised
2. Cannot isolate multiple concurrent projects' UI sessions
3. Create difficulty for agent-driven UI automation (Playwright) since it needs shared SDK access

We need a two-tier container architecture where browser windows are completely isolated but can share Chromium SDKs and automation tooling through a framework image.

**Constraints**:
- Browsers must not see host filesystem (/home, /root, config dirs)
- Browsers must not have host network access (only enclave + proxy)
- Browser process lifecycle must be owned by tray (no daemon that persists after tray exits)
- GPU acceleration is optional (performance optimization, not required)
- Chromium version must match Playwright's expectations for automation
- seccomp profile must allow headless rendering + WebSocket + GPU syscalls
- Rootless Podman: no CAP_SYS_ADMIN or privileged mode

**Stakeholders**: Tray app (owner), agents (Playwright consumers), infra (image builders), users (GPU enablement).

## Goals / Non-Goals

**Goals**:
- Complete process isolation: browser compromise cannot access host
- Ephemeral sessions: browser container cleaned up on window close
- Enclave-only networking: zero host network access
- Agent automation: Playwright runs inside framework container with shared SDK
- GPU acceleration support: optional hardware rendering for performance
- Minimal image size: core image < 250MB, framework < 600MB (cheatsheet: `build/podman-image-size.md`)

**Non-Goals**:
- Persistent browser profiles or session state
- User-facing browser customization (address bar, bookmarks, history)
- Cross-platform browser rendering (Linux only for MVP)
- Automated security updates (image rebuild cycle handles updates)
- Multi-user browser sandboxing (single forge user per container)

## Decisions

### 1. Two-Tier Image Architecture: Core + Framework

**Decision**: Separate `tillandsias-browser-core` (ephemeral window containers) and `tillandsias-browser-framework` (shared SDK + agents).

**Rationale**: Ephemeral windows should be minimal and fast to spawn (core image pulled from cache, spawned in <2s). Agents (Playwright, debugging tools) are heavier and used infrequently; baking them into a separate image avoids bloating every window instance.

**Alternatives Considered**:
- Single monolithic image: simpler but every window pays the full SDK cost; slower window spawn
- Dynamically layered images: more complexity in build pipeline; no significant benefit over pre-layered approach
- Sidecar SDK container: communication overhead; violates "tray owns process lifecycle" (SDK container would need its own lifecycle management)

**Implementation**: 
- `tillandsias-browser-core`: Fedora minimal + Chromium binary + dumb-init + seccomp
- `tillandsias-browser-framework`: Extends core with Playwright, Node.js agents, fonts, locale data
- Both use `--userns=keep-id` for rootless execution
- @trace spec:browser-core-image, spec:browser-framework-image

### 2. Tray-Owned Process Lifecycle

**Decision**: Tray app calls `podman run tillandsias-browser --rm` directly (not a daemon).

**Rationale**: Ephemeral model: when user closes window, `podman run` exits, `--rm` cleans container. No orphaned processes, no state accumulation, simple resource cleanup. Tray remains the single point of lifecycle control.

**Alternatives Considered**:
- Browser daemon (e.g., systemd service): persistent state, harder to clean up, violates "ephemeral sessions" goal
- Browser socket activation: complex systemd integration, adds maintenance burden
- Tray subprocess + browser background task: mixing concerns; tray shouldn't own browser process management

**Implementation**:
```rust
// In tray_spawn::spawn_browser_window(project, session_id)
podman_cmd_sync()
    .args(["run", "--rm", "-it", "--userns=keep-id", "--cap-drop=ALL",
           "--network=<enclave>", "--security-opt=no-new-privileges",
           "--tmpfs=/tmp", "--tmpfs=/home/chrome",
           "tillandsias-browser-core",
           "chromium", format!("opencode.{}.localhost/{}/", project, session_id)])
```
- @trace spec:browser-process-isolation

### 3. Filesystem Isolation: Read-Only Root + tmpfs Overlays

**Decision**: Container rootfs is read-only at runtime. Only /tmp, /home/chrome, /dev/shm writable via tmpfs.

**Rationale**: Prevents exfiltration of baked files (binaries, fonts, config templates). Chromium writes cache, profile data, and temp files to tmpfs; on container exit, all state is discarded. Protects against data retention across sessions.

**Alternatives Considered**:
- Shared writable /home: leaks data across sessions; increases attack surface
- Overlay2 with tmpfs upperdir: adds complexity; tmpfs-only approach is simpler
- Hardlinks to host /tmp: creates host filesystem dependency; violates isolation goal

**Implementation** (Containerfile):
```dockerfile
RUN curl -fsSL https://... | tar -xJ -C / && chown -R chrome:chrome /home/chrome
# ... RUN steps ...
USER chrome:chrome
VOLUME ["/tmp", "/home/chrome", "/dev/shm"]
```

**Runtime**:
```bash
podman run --tmpfs=/tmp:size=256m --tmpfs=/home/chrome:size=512m --tmpfs=/dev/shm:size=256m
```
- @trace spec:browser-filesystem-isolation
- @cheatsheet runtime/podman-security-flags.md

### 4. Enclave-Only Networking via Proxy Allowlist

**Decision**: Browser container has NO direct host network. All HTTP/HTTPS routed through proxy container with strict per-project allowlist.

**Rationale**: Prevents exfiltration to external services. Proxy enforces that browser can only reach:
- Enclave services (git, inference, other forge containers via internal DNS)
- Allowlisted external origins (e.g., fonts.googleapis.com for web fonts, cdn.jsdelivr.net for JS libraries)
- Project-specific origins (opencode.<project>.localhost:<port>)

**Alternatives Considered**:
- Host network + OS-level firewall rules: OS rules don't follow container lifecycle; decouples browser from Tillandsias' security model
- No network access: too restrictive; modern web UIs need external fonts, CDNs, APIs
- Direct access with IP tables: fragile; proxy provides observability

**Implementation**:
```bash
podman run \
    --network=<enclave-network> \
    --dns=<enclave-dns-ip> \
    --env HTTP_PROXY=http://proxy:3128 \
    --env HTTPS_PROXY=http://proxy:3128 \
    --env NO_PROXY=localhost,127.0.0.1,<enclave-services> \
    tillandsias-browser-core
```
- @trace spec:browser-enclave-networking
- @cheatsheet runtime/proxy-container.md (for Squid allowlist patterns)

### 5. GPU Acceleration on Wayland (Optional)

**Decision**: Support `--gpus=all` for hardware rendering; gracefully fallback to software rendering if unavailable.

**Rationale**: Web UI rendering is GPU-bound; hardware acceleration reduces latency and power consumption. Wayland + DRI/GBM supports GPU passthrough to containers without privileges. Fallback to software rendering if GPU unavailable (e.g., on headless hosts).

**Alternatives Considered**:
- Mandatory GPU: fails on headless/VM hosts; violates design constraint of graceful degradation
- Software rendering only: 5-10x slower; poor UX for dynamic agent web UIs
- X11 + GPU: deprecated path; Wayland is future

**Implementation** (Containerfile):
```dockerfile
RUN microdnf install -y mesa-dri-drivers libglvnd libglx0 libxext \
    && rm -rf /var/cache/*
```

**Runtime** (conditional):
```bash
# If host has GPU and DISPLAY=wayland-0:
podman run --gpus=all --device=/dev/dri --env WAYLAND_DISPLAY=wayland-0
# Else: fallback (no GPU flags, software rendering)
```
- @trace spec:browser-gpu-acceleration
- @cheatsheet runtime/wayland-gpu-passthrough.md

### 6. seccomp Hardening for Chromium

**Decision**: Custom seccomp profile that allows Chromium syscalls (mmap, mprotect, clone, epoll) but drops dangerous ones (execve in forked process, mount, ptrace, ioctl variants).

**Rationale**: Chromium makes many syscalls; default Docker seccomp denies too many and breaks rendering. Tailored profile reduces attack surface while maintaining compatibility.

**Alternatives Considered**:
- No seccomp (--security-opt seccomp=unconfined): removes key mitigation
- Default seccomp: breaks GPU rendering, WebGL, some JS JIT paths
- AppArmor: Linux-distribution-specific; less portable

**Implementation**:
```bash
# Create seccomp profile: cheatsheets/runtime/chromium-seccomp.json
podman run --security-opt seccomp=/etc/tillandsias/chromium.json
```
- @trace spec:browser-seccomp-hardening
- @cheatsheet runtime/chromium-seccomp.md

### 7. Playwright Vendoring in Framework Image

**Decision**: Bake Playwright (Node.js + browser binaries) into framework image at build time.

**Rationale**: Agents need Playwright for UI automation. Vendoring eliminates runtime download (no network dependency at runtime) and ensures binary compatibility with baked Chromium version. Framework image is heavier but infrequently spawned.

**Alternatives Considered**:
- Pull Playwright at runtime: network dependency; fails if proxy blocks Playwright registries
- Separate Playwright sidecar: increases complexity; harder to manage lifecycle
- Use system-installed Playwright: version skew risk; maintenance burden

**Implementation** (Containerfile):
```dockerfile
RUN npm install -g playwright@1.40.0 && \
    playwright install --with-deps chromium
```
- @trace spec:browser-playwright-integration

### 8. MCP Server for Window Control: open_safe_window / open_debug_window

**Decision**: Forge containers expose MCP tool functions `open_safe_window(url)` and `open_debug_window(url)` that forward to tray via shared socket.

**Rationale**: 
- Agents (Claude, OpenCode) and users (via tray) need to launch isolated browser windows with preset configurations (dark theme, hidden address bar, custom titles)
- Tray owns the browser process lifecycle and understands which project context we're in
- MCP servers run inside forge containers; they have no direct container spawning capability → forward to tray via IPC
- Window opening is rate-limited (10-second debounce) to prevent spam

**Constraints**:
- Agents can only open windows for their own project: `open_safe|debug_window("<service>.<same-project>.localhost")`
- Exception: any agent can open `open_safe_window("dashboard.localhost")` (future user dashboard, no debug variant)
- No debug windows for external origins (e.g., no `open_debug_window("external.com")`)
- Tray enforces rate limit: no two windows for the same project within 10 seconds

**Window types**:
1. **open_safe_window(url)** — User-facing, safe defaults:
   - Dark theme (Tokyonight)
   - Hidden address bar (no URL exposed)
   - Custom window title (`<project>: <service>`)
   - No dev tools visible
   - Read-only isolation (no external network)
   - Available to agents + tray + users

2. **open_debug_window(url)** — Developer-facing, full controls:
   - Same isolation as safe window
   - Chrome DevTools enabled on localhost:9222
   - Address bar visible (debugging aid)
   - Inspector console available
   - Available to agents only (not tray, not users)

**Implementation**:

*Forge MCP server* (`images/default/mcp-server-browser.js`):
```javascript
// @trace spec:browser-mcp-server
// MCP server running inside forge containers
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic();

export const tools = [
  {
    name: "open_safe_window",
    description: "Open a URL in an isolated safe browser window (dark theme, hidden URL, no devtools)",
    input_schema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to open (must be <service>.<project>.localhost or dashboard.localhost)" }
      },
      required: ["url"]
    }
  },
  {
    name: "open_debug_window",
    description: "Open a URL in an isolated debug browser window (devtools enabled, inspector visible)",
    input_schema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to open (must be <service>.<same-project>.localhost)" }
      },
      required: ["url"]
    }
  }
];

export async function processTool(name, input) {
  if (name === "open_safe_window" || name === "open_debug_window") {
    // Forward to tray via shared socket (/run/tillandsias/tray.sock)
    const response = await fetch("unix:///run/tillandsias/tray.sock/browser/window", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: name,
        url: input.url,
        project: process.env.TILLANDSIAS_PROJECT,
        timestamp: Date.now()
      })
    });
    return await response.json();
  }
}
```

*Tray handler* (`src-tauri/src/browser.rs`):
```rust
// @trace spec:browser-mcp-server
// Socket server listening for MCP window requests from forge containers

pub struct WindowRequest {
    pub action: String,  // "open_safe_window" or "open_debug_window"
    pub url: String,
    pub project: String,
}

pub struct WindowDebounce {
    last_window_time: HashMap<String, Instant>,
    debounce_secs: u64,  // 10 seconds
}

impl WindowDebounce {
    pub fn is_allowed(&mut self, project: &str) -> bool {
        let now = Instant::now();
        if let Some(last_time) = self.last_window_time.get(project) {
            if now.duration_since(*last_time).as_secs() < self.debounce_secs {
                return false;  // Too soon, debounce
            }
        }
        self.last_window_time.insert(project.to_string(), now);
        true
    }
}

pub async fn handle_window_request(req: WindowRequest) -> Result<()> {
    // Validation
    if !is_safe_url(&req.url, &req.project) {
        return Err("URL not allowed for this project".into());
    }
    
    // Rate limit
    if !WINDOW_DEBOUNCE.lock().is_allowed(&req.project) {
        return Err("Window opening rate limited (10 seconds between windows)".into());
    }
    
    // Spawn container (same logic as user-initiated window opening)
    spawn_chromium_window(
        &req.project,
        &req.url,
        req.action == "open_debug_window"
    ).await?;
    
    Ok(())
}

fn is_safe_url(url: &str, project: &str) -> bool {
    // Allow: <service>.<project>.localhost for agent's own project
    if url.contains(".localhost") && url.contains(project) {
        return true;
    }
    // Allow: dashboard.localhost for anyone
    if url == "dashboard.localhost" {
        return true;
    }
    false
}
```

- @trace spec:browser-mcp-server

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| **GPU driver mismatch** | No GPU available on host → fallback to software rendering. Document GPU prerequisites in setup guide. |
| **Proxy becomes bottleneck** | High-throughput multimedia (video CDN) through proxy is slow. Mitigate: add bandwidth monitoring, allow direct CDN access for video origins (separate spec). |
| **tmpfs size limits** | Browser cache, profile, temp files grow unbounded → OOM on small VMs. Mitigate: hardcode tmpfs size limits (256MB /tmp, 512MB /home/chrome); add warning if approaching limit. |
| **Seccomp breaking future Chromium** | New Chromium versions use new syscalls → seccomp blocks them. Mitigate: test seccomp profile against Chromium ESR releases in CI. |
| **Window spawn latency** | First window takes longer (image pull, container creation overhead). Mitigate: document that first launch is slow; subsequent windows are fast (cached layers). |
| **Session isolation complexity** | Multiple sessions in same framework container violates per-session isolation goal. Mitigate: each browser window is its own core-image container; framework container is optional (used only for Playwright workloads). |

**Trade-off**: Complexity vs. Security. Full isolation requires container overhead; simplified designs (no seccomp, shared /home) are faster but leak data. Current design accepts container overhead for strong isolation.

## Migration Plan

**Phase 1: Image build pipeline** (Design spec)
- Add `tillandsias-browser-core` and `tillandsias-browser-framework` Containerfiles to `images/`
- Update `scripts/build-image.sh` to build both (or use Nix flake for layered builds)
- Test image builds locally

**Phase 2: Tray app integration** (Implementation spec)
- Add `tray_spawn::spawn_browser_window(project, session_id)` function in Rust
- Update tray menu to add "Open Browser" action for projects
- Test browser window spawn and lifecycle

**Phase 3: Agent integration** (Future: separate spec)
- Wire up Playwright in framework container
- Add agent commands for UI automation
- Document Playwright usage patterns

**Phase 4: Deployment** (Release notes)
- New browser isolation is opt-in (no breaking changes to existing forge containers)
- Tray v0.2.0+ gains `--browser` CLI flag for browser-only mode
- Image builds in CI/CD pipeline; no manual image management needed

**Rollback**: Disable `spawn_browser_window()` calls in tray; browser windows won't launch but existing forge/agent functionality unchanged.

## Open Questions

1. **Session timeout & cleanup**: If user leaves browser window open, container keeps running. Should tray auto-close windows after 30 min of inactivity? Or let user manage?
   - Proposal: Auto-close with user confirmation dialog (configurable timeout)

2. **Multiple monitors**: If user has multiple monitors, should browser windows pin to specific monitors or be unmanaged?
   - Proposal: Unmanaged (user can move windows); document in setup guide

3. **Browser extensions**: Should we allow user-installed browser extensions (password managers, ad blockers)?
   - Proposal: No extensions in MVP (sandboxed model prevents extension IPC); future spec if requested

4. **Persistent favorites/bookmarks**: Browser is ephemeral; should tray cache "frequently accessed" origins?
   - Proposal: No in MVP; future feature if UX feedback warrants

5. **seccomp profile maintenance**: Who owns updating seccomp profile as Chromium evolves?
   - Proposal: Add to release checklist; test against Chromium ESR version in use

---

## Sources of Truth

- `cheatsheets/runtime/podman-security-flags.md` — podman security flags (--userns, --cap-drop, seccomp, etc)
- `cheatsheets/runtime/wayland-gpu-passthrough.md` — GPU passthrough on Wayland + DRI/GBM
- `cheatsheets/runtime/chromium-seccomp.md` — Chromium-compatible seccomp profile
- `cheatsheets/runtime/proxy-container.md` — Squid allowlist patterns and HTTP_PROXY environment handling

## @trace spec:browser-core-image, spec:browser-framework-image, spec:browser-process-isolation, spec:browser-url-injection, spec:browser-enclave-networking, spec:browser-filesystem-isolation, spec:browser-gpu-acceleration, spec:browser-seccomp-hardening, spec:browser-playwright-integration, spec:tray-cli-coexistence

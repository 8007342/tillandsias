## Why

Tillandsias' tray app currently lacks hardened browser isolation for displaying project UIs and agent web sessions. Browser windows inherit host credentials, network access, and filesystem privileges — creating attack surface and data leakage vectors. We need a two-tier containerized Chromium architecture that isolates browser processes completely from the host while maintaining enclave-only network access and zero credential exposure.

This solves three problems: (1) browser compromise cannot leak host credentials or access unrelated projects, (2) process lifecycle is owned entirely by the tray app (ephemeral sessions on container exit), (3) no host filesystem access and sandboxed XDG directories prevent data exfiltration.

## What Changes

- **New container images**: `tillandsias-browser-core` (minimal, ephemeral Chromium) and `tillandsias-browser-framework` (SDK, agents, Playwright)
- **Tray app gains podman run ownership**: Tray spawns browser windows via `podman run tillandsias-browser --rootless-fedora-minimal --only-enclave-network-through-proxy opencode.<project>.localhost/<session_id>/`
- **URL injection model**: No user-visible URL bar; tray injects `opencode.<project>.localhost:<ephemeral-port>/<session_id>/` as the only accessible origin
- **Read-only rootfs**: Container filesystem is read-only at runtime; only tmpfs overlays on /tmp, /home, and agent state directories are writable
- **Enclave-only networking**: Browser has zero host network access; all HTTP/HTTPS routed through proxy container with strict allowlist
- **Playwright vendored**: Browser automation tooling baked into framework image for agent use
- **Quadlet autostart integration**: Optional systemd/Quadlet startup for daemon mode (future)
- **seccomp tuned for Chromium**: Restrictive seccomp profile allowing only syscalls needed for GPU-accelerated headless rendering
- **GPU acceleration on Wayland**: Hardware acceleration for web rendering via GPU passthrough on Wayland-capable hosts
- **Non-breaking**: Existing tray UI unaffected; browser isolation is opt-in per-project via config

## Capabilities

### New Capabilities

- `browser-core-image`: Ultra-minimal Fedora rootless Chromium image (base layer, ~200MB)
- `browser-framework-image`: Chromium SDK + agents + Playwright + fonts (framework layer, ~500MB)
- `browser-process-isolation`: Two-tier process isolation (core for ephemeral windows, framework for shared daemon)
- `browser-url-injection`: Tray-owned URL injection model (no address bar, fixed origin per session)
- `browser-enclave-networking`: Proxy-only network access with strict allowlist per project
- `browser-filesystem-isolation`: Read-only rootfs + tmpfs overlays for ephemeral state
- `browser-gpu-acceleration`: Hardware GPU passthrough for Wayland-based rendering
- `browser-seccomp-hardening`: Chromium-specific seccomp profile for attack surface reduction
- `browser-playwright-integration`: Vendored Playwright for agent automation inside framework container

### Modified Capabilities

- `tray-cli-coexistence`: Tray gains `podman run` lifecycle ownership for browser windows (was CLI-only before)

## Impact

- **Tray app**: New browser window spawning via `tray_spawn::spawn_browser_window()` function; owns process lifecycle entirely
- **Containers**: Two new container images (tillandsias-browser-core, tillandsias-browser-framework) alongside existing enclave images
- **Network**: Browser traffic must route through proxy (no direct host network)
- **Filesystem**: No access to host filesystem; sandboxed XDG directories only
- **GPU drivers**: Requires GPU passthrough support on host for acceleration (optional; falls back to software rendering)
- **Configuration**: Project config gains optional `browser.session-timeout`, `browser.enable-gpu`, `browser.sandbox-level` keys
- **CLI**: `tillandsias <project> --browser` to launch browser-only mode (no coding environment)


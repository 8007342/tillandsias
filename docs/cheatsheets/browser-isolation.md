# Browser Isolation for OpenCode Web

**Provenance**: `@trace spec:browser-isolation-core, spec:browser-isolation-framework`  
**Spec**: `openspec/specs/opencode-web-session/spec.md`  
**Change**: `openspec/changes/design-chromium-browser-isolation/`  

## Overview

Tillandsias runs OpenCode Web inside a container, but the browser must also be isolated. Two Chromium images provide this:

| Image | Purpose | Packages |
|-------|---------|----------|
| `tillandsias-chromium-core:vX.Y.Z.B` | Secure, headless browser | Chromium headless, mesa-dri-drivers |
| `tillandsias-chromium-framework:vX.Y.Z.B` | Debug browser with DevTools | Node.js, npm, Playwright, DevTools |

**Versioning**: Both images use the full Tillandsias version tag (`vX.Y.Z.B`) matching the running binary. No `:latest` tags are used. @trace spec:versioning

## How It Works

```
HOST (Tillandsias Tray)
  ├── Unix Socket: /run/tillandsias/tray.sock
  │     ↑ listens for browser requests
  └── event_loop.rs → handle_open_browser_window()
       └── chromium_launcher::spawn_chromium_window()
            └── launch-chromium.sh → podman run tillandsias-chromium-*

FORGE CONTAINER (tillandsias-forge)
  ├── OpenCode Web (opencode serve --port 4096)
  ├── tillandsias-browser-tool (at /usr/local/bin/)
  │     └── Connects to /run/tillandsias/tray.sock
  │           (mounted from host $XDG_RUNTIME_DIR/tillandsias/tray.sock)
  └── OPENCODE_BROWSER="safe" (env var)
        └── OpenCode calls: tillandsias-browser-tool safe <url>
              └── Sends JSON to tray socket → opens chromium container
```

## Key Security Features

1. **Tray socket mounted**: `/run/tillandsias/tray.sock` is bind-mounted into the forge container
2. **Browser runs in container**: Chromium executes inside `tillandsias-chromium-core`, not on host
3. **No credential access**: Chromium container has `--cap-drop=ALL`, `--security-opt=no-new-privileges`
4. **Isolated from project**: Browser container shares no volumes with the project directory

## Building Browser Containers

### Via `tillandsias --init` (automatic)

```bash
tillandsias --init
# Builds: proxy, forge, git, inference, chromium-core, chromium-framework
```

The `--init` sequence now includes all 6 container images. @trace spec:init-incremental-builds

### Versioned Tags (Non-Interactive Build)

Both chromium images use **versioned tags** that match the running Tillandsias binary:

```bash
# Core (minimal, secure) - tag matches binary version
podman build \
  --tag "tillandsias-chromium-core:v$(cat VERSION)" \
  -f images/chromium/Containerfile.core \
  images/chromium/
```

```bash
# Framework (debug, with Node.js + Playwright) - extends versioned core
podman build \
  --build-arg CHROMIUM_CORE_TAG="v$(cat VERSION)" \
  --tag "tillandsias-chromium-framework:v$(cat VERSION)" \
  -f images/chromium/Containerfile.framework \
  images/chromium/
```

**The `chromium-framework` Containerfile accepts `CHROMIUM_CORE_TAG` as a build arg** to avoid interactive prompts and ensure the exact same-version core image is used. @trace spec:versioning

### Manual build (development only)

```bash
# Core
podman build -f images/chromium/Containerfile.core \
  -t tillandsias-chromium-core:v0.1.160.204 images/chromium/

# Framework (extends core with SDK tools)
podman build --build-arg CHROMIUM_CORE_TAG=v0.1.160.204 \
  -f images/chromium/Containerfile.framework \
  -t tillandsias-chromium-framework:v0.1.160.204 images/chromium/
```

## Verifying Isolation

```bash
# Check browser containers exist with versioned tags
podman images | grep chromium

# Check tray socket is mounted in forge container
podman inspect tillandsias-forge:v0.1.160.203 | grep tray.sock

# Test OpenCode Web session
tillandsias /path/to/project --opencode
# Then in OpenCode Web, click a link → should open in Chromium container
```

## Troubleshooting

### "Tray socket not found" error

The `tillandsias-browser-tool` inside the forge container needs the tray socket at `/run/tillandsias/tray.sock`. If you see this error:

1. Verify Tillandsias tray is running: `pgrep -x tillandsias`
2. Check socket exists: `ls -la /run/tillandsias/tray.sock`
3. The mount is added automatically in `common_forge_mounts()` (container_profile.rs)

### Browser opens on host instead of container

If links open in your native browser:

1. Check `OPENCODE_BROWSER` env var inside container:
   ```bash
   podman exec tillandsias-forge-<project>-<genus> env | grep OPENCODE_BROWSER
   # Should print: OPENCODE_BROWSER=safe
   ```
2. Check `tillandsias-browser-tool` exists in container:
   ```bash
   podman exec tillandsias-forge-<project>-<genus> which tillandsias-browser-tool
   # Should print: /usr/local/bin/tillandsias-browser-tool
   ```
3. Check browser tool can reach tray:
   ```bash
   podman exec tillandsias-forge-<project>-<genus> \
     tillandsias-browser-tool safe http://127.0.0.1:4096
   # Should open Chromium container window
   ```

## Implementation Details

| Component | File | Trace |
|-----------|------|-------|
| Chromium Containerfiles | `images/chromium/Containerfile.core`, `Containerfile.framework` | `spec:browser-isolation-core`, `spec:browser-isolation-framework`, `spec:versioning` |
| Build integration | `scripts/build-image.sh` | `spec:browser-isolation-core`, `spec:versioning` |
| Init sequence | `src-tauri/src/init.rs:114-121` | `spec:init-incremental-builds` |
| Tag functions | `src-tauri/src/handlers.rs:106-116` | `spec:browser-isolation-core`, `spec:versioning` |
| Mount definitions | `crates/tillandsias-core/src/container_profile.rs:86-92` | `spec:mcp-on-demand` |
| Socket resolution | `src-tauri/src/launch.rs:433-448` | `spec:mcp-on-demand` |
| Browser launcher | `scripts/launch-chromium.sh` | `spec:browser-isolation-core` |

## OpenCode Web vs CLI

| Mode | Browser | Isolation |
|------|---------|-----------|
| `tillandsias <path> --opencode` | Host terminal (TTY) | None (CLI only) |
| `tillandsias <path> --opencode-web` | Container (Chromium) | Full (browser in container) |
| `tillandsias <path> --claude` | Host terminal (TTY) | None (CLI only) |

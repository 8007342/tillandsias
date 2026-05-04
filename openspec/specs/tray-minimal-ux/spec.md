# spec: tray-minimal-ux

## Status

active

**Version:** v1.0

**Purpose:** Define the minimalistic tray UX flow for Tillandsias, showing only essential elements at each stage of the application lifecycle and enabling dynamic project launches.

<!-- @trace spec:tray-minimal-ux -->

## Requirements

### Requirement 1: First-launch minimal tray
**Modality:** MUST

The tray MUST display exactly four elements when Tillandsias starts:
1. Dynamic status element: `<Checklist> Verifying environment ...` (with animation)
2. Visual divider
3. Version attribution: `Tillandsias vX.Y.Z + Attributions` (disabled, non-clickable)
4. Quit action: `Quit Tillandsias` (enabled, terminates tray gracefully)

**Measurable:** Menu item count = 4; no project submenu items visible; no cloud items visible; no GitHub login button visible.

**Scenario:** When tray launches on a fresh or cold-start state, verify `podman ps` contains no tillandsias containers and observe that only the four elements render in the menu.

---

### Requirement 2: Dynamic environment verification status
**Modality:** MUST

The first tray element MUST update dynamically as enclave containers transition through build states:

| State | Display Text | Icon Progression |
|-------|--------------|------------------|
| Initial | `<Checklist> Verifying environment ...` | ☐ (checklist) |
| After proxy ready | `<Checklist><Network> Building enclave ...` | ☐🌐 |
| After git ready | `<Checklist><Network><Mirror> Building git mirror ...` | ☐🌐🪞 |
| All images healthy | `<Checklist><Network><Mirror><Browser> ✓ Environment OK` | ☐🌐🪞🧠 |
| Build failure | `<WhiteRose> Unhealthy environment` | 🌹 |

**Measurable:** Menu element 1 text changes as tracked by `TrayState::enclave_status` field; icon glyphs match above table; transitions happen within 2 seconds of container health detection.

**Scenario:** Start tray in a clean environment; observe status text changes from "Verifying..." → "Building enclave..." → "Building git mirror..." → "Environment OK" as containers initialize. Trigger a container build failure and verify the status switches to "Unhealthy environment" with 🌹 icon.

---

### Requirement 3: Post-initialization menu expansion
**Modality:** MUST

Once all enclave images are healthy (`enclave_status == OK`), the tray MUST conditionally add menu items:

- If local projects exist: `<Home> ~/src >` submenu (lists local projects)
- If GitHub authenticated AND remote projects readable: `<Cloud> Cloud >` submenu (lists remote projects)
- If NOT authenticated: `<Key> GitHub login` action button

**Measurable:** Menu grows from 4 items to 6–7 items (local projects, cloud projects, and/or GitHub login); items appear only when conditions are met; state transitions logged with `spec = "tray-minimal-ux"`.

**Scenario:** Start tray, wait for "Environment OK" status, then verify local projects appear in the menu. Add GitHub credentials (via login action) and verify `<Cloud>` submenu appears within 3 seconds.

---

### Requirement 4: Project launch flow
**Modality:** MUST

When a user clicks a project in the tray menu, Tillandsias MUST:
1. If project is remote (not cloned): clone it locally to the watch directory first
2. Launch an OpenCode Web container (`tillandsias-<project>-opencode-web`) with the project directory
3. Monitor container health via port 4096 readiness check
4. Once healthy, launch a safe browser window via `tillandsias-chromium-core` container
5. Browser MUST communicate with OpenCode Web through the tray socket mount (`/run/tillandsias/tray.sock`)

**Measurable:** Git clone completes (0 exit code); container becomes healthy within 30 seconds; browser window PID is logged with `spec = "tray-minimal-ux"`; tray socket is mounted into browser container.

**Scenario:** Click a local project; verify OpenCode Web container starts. Click a remote project; verify git clone happens, then container starts. In both cases, verify safe browser window opens with correct OpenCode Web URL.

---

### Requirement 5: Stale container cleanup
**Modality:** MUST

On tray startup, Tillandsias MUST:
1. List all containers matching `tillandsias-*` pattern
2. Compare against `TrayState::containers` (tracked containers)
3. Remove any stopped or orphaned containers
4. Log cleanup actions with `spec = "tray-minimal-ux"`, `action = "cleanup"`

**Measurable:** Cleanup log entries appear in startup phase; `podman ps -a | grep tillandsias` shows only actively tracked containers after startup completes.

**Scenario:** Manually create an orphaned container with `podman run --name tillandsias-orphan ...`, then start the tray. Verify the container is removed during startup.

---

### Requirement 6: Annotation enforcement
**Modality:** MUST

All code implementing this spec MUST be annotated with `@trace spec:tray-minimal-ux` near the relevant function or block.

**Measurable:** `git grep -n '@trace spec:tray-minimal-ux'` returns at least one hit per major code path (menu builder, status updater, project launcher, cleanup handler).

---

---

## Invariants

1. **Menu is never empty**: The quit button is always visible, even if enclave initialization fails.
2. **Status is always updated**: The status element updates atomically; no partial states are rendered.
3. **Project directory is always local**: Remote projects are cloned before container launch; forge container always has a valid project directory.
4. **Tray socket is always mounted**: Browser containers always receive the tray socket; no browser launch happens without it.

---

## Litmus Tests

### Test 1: Launch state has exactly 4 items
```bash
# Start tray in a fresh state (no containers running)
podman ps | wc -l  # Should be empty or only tray
tillandsias &
TRAY_PID=$!
sleep 2

# Verify menu has 4 items (via tray RPC or inspect)
# Expected: [Status, Divider, Version, Quit]
# NOT expected: [Status, Divider, Version, Quit, Project1, Project2, ...]
```

### Test 2: Status updates as containers initialize
```bash
# Monitor tray menu updates via logs or RPC
# Expected progression:
# T+0: "Verifying environment..."
# T+5: "Building enclave..." (after proxy container healthy)
# T+10: "Building git mirror..." (after git container healthy)
# T+20: "✓ Environment OK" (after all containers healthy)
```

### Test 3: Projects appear after initialization
```bash
# Wait for status = OK
# Verify ~/src submenu now shows local projects
# Verify Cloud submenu shows if authenticated
# Count: menu should have 6–7 items (not 4)
```

### Test 4: Clicking a local project launches browser
```bash
# Click a local project in tray menu
# Wait 5 seconds
# Verify: OpenCode Web container running AND browser window visible with OpenCode Web URL
```

### Test 5: Clicking a remote project clones then launches
```bash
# Click a remote project that doesn't exist locally
# Monitor: git clone should complete within 30 seconds
# Verify: Project now exists in ~/src
# Verify: OpenCode Web container running AND browser window visible
```

### Test 6: Stale containers are cleaned on startup
```bash
# Manually create: podman run --name tillandsias-stale alpine sleep 3600
# Start tray
# Verify: tillandsias-stale container is removed during startup
# Verify: Actively tracked containers (proxy, git, forge) are preserved
```

---

## Sources of Truth

- `docs/cheatsheets/tray-minimal-ux.md` — Tray UX stages, menu structure, and implementation reference
- `cheatsheets/runtime/podman.md` — Container lifecycle, health checks, and cleanup patterns
- `cheatsheets/runtime/unix-socket-ipc.md` — Tray socket mounting and browser-to-forge communication

---

## Implementation References

- **Menu builder**: `src-tauri/src/menu.rs` → `build_tray_menu()`
- **Status updater**: `src-tauri/src/handlers.rs` → `update_environment_status()`
- **Project launcher**: `src-tauri/src/handlers.rs` → `handle_*_project()` functions
- **Cleanup logic**: `src-tauri/src/handlers.rs` → `cleanup_stale_containers()`
- **Events**: `crates/tillandsias-core/src/event.rs` → `MenuCommand` enum

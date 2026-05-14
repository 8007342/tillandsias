# spec: tray-minimal-ux

## Status

active

**Version:** v1.1 (supersedes v1.0)

**Purpose:** Define the minimalistic tray UX flow for Tillandsias, showing only essential elements at each stage of the application lifecycle and exposing the Seedlings plus per-project submenus once the enclave is ready.

<!-- @trace spec:tray-minimal-ux -->

## Requirements

### Requirement 1: First-launch minimal tray
**Modality:** MUST

The tray MUST display exactly four elements when Tillandsias starts:
1. Dynamic status element: `<Checklist> Verifying environment ...` (with animation)
2. Visual divider
3. Version attribution: `Tillandsias vX.Y.Z + Attributions` (disabled, non-clickable)
4. Quit action: `Quit Tillandsias` (enabled, terminates tray gracefully)

**Measurable:** Menu item count = 4; no Seedlings submenu visible; no project submenu items visible; no cloud items visible; no GitHub login button visible.

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

- `Seedlings` submenu listing `OpenCode Web`, `OpenCode`, and `Claude` in that order, with the active choice preserved from `SelectedAgent`
- One submenu per local project, labeled with the project name
- `GitHub Login` action button

**Measurable:** Menu grows from 4 items to 5+ items; the dynamic region appears only when conditions are met; the Seedlings submenu preserves its stable order and active choice; state transitions are logged with `spec = "tray-minimal-ux"`.

**Scenario:** Start tray, wait for "Environment OK" status, then verify the `Seedlings` submenu appears first in the dynamic region, followed by per-project submenus and the `GitHub Login` action.

---

### Requirement 4: Project launch flow
**Modality:** MUST_NOT

This spec MUST NOT own project launch, browser session wiring, or tray socket behavior. Those behaviors are owned by `spec:tray-app` and `spec:browser-isolation-tray-integration`.

**Measurable:** No assertion in this spec requires container launch, browser launch, or tray socket mounting.

**Scenario:** N/A. Use the owning specs for project-launch behavior.

---

### Requirement 5: Stale container cleanup
**Modality:** MUST_NOT

This spec MUST NOT own stale-container cleanup at tray startup. Cleanup is owned by the tray/runtime lifecycle contract, not the minimal tray menu contract.

**Measurable:** No assertion in this spec requires container enumeration or removal on startup.

**Scenario:** N/A. Use the runtime lifecycle and tray-app specs for cleanup behavior.

---

### Requirement 6: Annotation enforcement
**Modality:** MUST

All code implementing this spec MUST be annotated with `@trace spec:tray-minimal-ux` near the relevant function or block.

**Measurable:** `git grep -n '@trace spec:tray-minimal-ux'` returns at least one hit per major code path (menu builder, status updater, Seedlings submenu, per-project submenu).

---

---

## Invariants

1. **Menu is never empty**: The quit button is always visible, even if enclave initialization fails.
2. **Status is always updated**: The status element updates atomically; no partial states are rendered.

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
# NOT expected: [Status, Divider, Version, Quit, Seedlings, Project1, ...]
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
# Verify Seedlings submenu now shows OpenCode Web, OpenCode, and Claude in that order
# Verify per-project submenus appear by project name
# Count: menu should have 5+ items (not 4)
```

### Test 4: Seedlings submenu keeps stable order
```bash
# Verify the Seedlings submenu exists and the items are ordered:
# OpenCode Web -> OpenCode -> Claude
# Verify the active selection stays on the configured agent
```

### Test 5: Per-project submenus are present after readiness
```bash
# Wait for Environment OK
# Verify each local project appears under its own submenu label
# Verify GitHub Login remains available in the dynamic region
```

---

## Sources of Truth

- `openspec/specs/tray-app/spec.md` — current tray menu ownership for Seedlings and per-project submenus
- `cheatsheets/runtime/tray-state-machine.md` — stage transitions and menu visibility rules
- `cheatsheets/runtime/statusnotifier-tray.md` — Linux tray protocol contract and menu shape
- `openspec/specs/browser-isolation-tray-integration/spec.md` — owning spec for the tombstoned browser/session flow

---

## Implementation References

- **Menu builder**: `src-tauri/src/menu.rs` → `build_tray_menu()`
- **Status updater**: `src-tauri/src/handlers.rs` → `update_environment_status()`
- **Seedlings submenu**: `crates/tillandsias-headless/src/tray/mod.rs` → `build_seedlings_submenu()`
- **Per-project submenu**: `crates/tillandsias-headless/src/tray/mod.rs` → `build_project_submenu()`
- **Events**: `crates/tillandsias-core/src/event.rs` → `MenuCommand` enum

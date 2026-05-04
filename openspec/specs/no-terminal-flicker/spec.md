# spec: no-terminal-flicker

## Status

active

**Version:** v1.0

**Purpose:** Define strategies for eliminating visual flicker and unwanted console window appearances when Tillandsias launches processes on Windows and Linux/macOS, ensuring a smooth, professional user experience.

<!-- @trace spec:no-terminal-flicker -->

## Requirements

### Requirement 1: Windows background process suppression

On Windows, all background podman operations (container status checks, image pulls, deletions) MUST:
1. Use `CREATE_NO_WINDOW` flag when spawning processes (suppresses console window flash)
2. Redirect stdio to pipes (null or capture) to prevent console output from appearing
3. NOT display output to console (errors are logged instead)

**Measurable:** When running tillandsias-podman background operations, no console window appears on screen; operations complete silently; errors are logged to `~/.cache/tillandsias/tillandsias.log`, not printed to stdout.

**Scenario:** Start the tray, which launches background container checks. Observe zero console window flashes. Verify logs contain any errors from those checks.

---

### Requirement 2: Windows interactive terminal preservation

On Windows, interactive podman operations (terminal shells, attach-here) MUST:
1. Use raw `Command::new()` instead of `podman_cmd_sync()` to launch interactive processes
2. NOT apply `CREATE_NO_WINDOW` flag (allows user terminal to display)
3. Inherit stdio from the parent tray process (user input flows through)
4. Wait for the process to complete before returning

**Measurable:** When launching "Attach Here" or terminal commands, a terminal window appears with user's shell. User input is echoed correctly. `CREATE_NO_WINDOW` is NOT set on the parent Command object.

**Scenario:** Click "Attach Here" or "Root Terminal" in the tray menu. Verify a terminal window appears and accepts user input normally.

---

### Requirement 3: Tray menu rebuilt only on state change

The tray menu MUST be pre-built once at startup and then updated (not rebuilt) when state changes:
1. All static menu items are created once (Quit, Settings, Version, etc.)
2. Only the Projects submenu is rebuilt when the project list changes
3. Stage transitions (Booting → Ready → NoAuth → Authed) toggle item enabled/disabled status, not rebuild
4. Menu updates are atomic: no partial menu states visible to user

**Measurable:** Menu rebuild happens zero times after startup (except project list changes); state transitions take <100ms; no flicker or item rearrangement visible during state changes.

**Scenario:** Start the tray and watch the status change from "Verifying..." → "Ready". Observe no menu flicker, no items disappearing/reappearing, only the text updating.

---

### Requirement 4: Stage visibility lookup table

Tray menu visibility MUST be driven by a static lookup table mapping `Stage` (Booting, Ready, NoAuth, Authed, NetIssue) to item visibility:

| Item | Booting | Ready | NoAuth | Authed | NetIssue |
|------|---------|-------|--------|--------|----------|
| Status indicator | ✓ enabled | ✓ enabled | ✓ enabled | ✓ enabled | ✓ enabled |
| Divider | ✓ | ✓ | ✓ | ✓ | ✓ |
| Version/Attribution | disabled | disabled | disabled | disabled | disabled |
| Quit | ✓ enabled | ✓ enabled | ✓ enabled | ✓ enabled | ✓ enabled |
| Home (~/src) | — | — | — | ✓ enabled | — |
| Cloud (remote) | — | — | — | ✓ enabled | — |
| GitHub Login | — | — | ✓ enabled | — | — |
| Settings | — | — | — | ✓ enabled | — |

**Measurable:** Menu item visibility matches the table for each stage; no stage omissions; lookup is O(1) (no conditional logic).

**Scenario:** Verify the visibility table in code matches the above. Transition through stages and verify items appear/disappear per the table.

---

### Requirement 5: Menu label updates without rebuild

When menu labels change (e.g., status text, building chip, project count), the update MUST:
1. Call `set_text()` on the existing menu item handle (not recreate the item)
2. Complete within 50ms
3. NOT rebuild the submenu structure

**Measurable:** Menu item count stays constant; only text changes between state updates; updates complete in <50ms as measured by log timestamps.

**Scenario:** Observe the status text changing from "Verifying..." → "Building enclave..." → "Environment OK". Verify the menu item count remains constant and the menu doesn't flicker.

---

### Requirement 6: Project list rebuild guard

The Projects submenu SHOULD only rebuild when:
1. The set of local projects changes (e.g., a new project is added to ~/src)
2. The remote project list changes (after GitHub auth or refresh)
3. The `include_remote` flag toggles (user auth status changes)

**Measurable:** Projects submenu is rebuilt <5 times during a 10-minute user session; rebuild is triggered by explicit state changes (not periodic polling); rebuild time is <200ms.

**Scenario:** Start the tray, authenticate with GitHub, and verify the Projects submenu rebuilds once. Add a new project to ~/src and verify submenu rebuilds again. During normal operation, verify minimal rebuilds.

---

### Requirement 7: No periodic menu polling

The tray MUST NOT:
1. Poll the menu state on a timer
2. Rebuild the menu in response to unrelated events
3. Trigger menu updates from non-critical operations (image checks, status polling)

**Measurable:** No `tokio::interval()` or `std::thread::sleep()` loops that trigger menu updates; menu updates are only triggered by explicit state changes (health checks, user auth, project list changes).

**Scenario:** Monitor the tray logs. Verify menu updates are logged only when state changes (startup, GitHub auth, new project), not on a periodic schedule.

---

### Requirement 8: macOS and Linux terminal consistency

On macOS and Linux, terminal launches SHOULD:
1. Use platform-native terminal (Terminal.app on macOS, terminal emulator on Linux)
2. Inherit stdio and TTY from the tray process
3. Not flash or flicker when opened
4. Support interactive shells (bash, zsh) with full I/O

**Measurable:** Terminal opens smoothly without visual artifacts; user input/output works correctly; no console window appears (X11/Wayland window management is native).

**Scenario:** On macOS, click "Attach Here". Verify Terminal.app opens (not a generic console). On Linux, verify the configured terminal emulator opens (GNOME Terminal, Konsole, etc.).

---

## Invariants

1. **Menu is always responsive**: State transitions complete within 100ms; user never sees a "frozen" menu.
2. **No unwanted console windows**: Windows users never see unexpected console windows during normal operation.
3. **Interactive terminals always work**: When user needs a terminal, it opens and accepts input normally.
4. **Menu structure is stable**: Project list changes do NOT cause static menu items to move or disappear.

---

## Litmus Tests

### Test 1: No console flicker on startup
```bash
# On Windows, start the tray
# Observe for 10 seconds
# Expected: no console windows appear; tray menu is visible and responsive
```

### Test 2: Menu has exact item count at each stage
```bash
# Start tray in Booting stage
# Count visible menu items: should be 4 (Status, Divider, Version, Quit)

# Wait for Ready stage
# Count items: should still be 4

# Authenticate with GitHub (NoAuth → Authed)
# Count items: should be 6–7 (add Home, Cloud, Settings)
```

### Test 3: Status text updates without menu rebuild
```bash
# Monitor tray RPC or logs
# Start tray and observe status text changes:
# "Verifying..." → "Building enclave..." → "Environment OK"
# Expected: menu item IDs remain constant; only text changes
```

### Test 4: Projects submenu rebuilds on list change
```bash
# Start tray and note Projects submenu
# Add a new project to ~/src: mkdir -p ~/src/new-project
# Verify: Projects submenu refreshes within 2 seconds (shows new project)
# Verify: other menu items are unchanged (no rebuild of Status, Quit, etc.)
```

### Test 5: Interactive terminal works
```bash
# On Windows, click "Root Terminal" or "Attach Here"
# Verify: terminal window opens (Terminal.app on macOS, terminal emulator on Linux, cmd/PowerShell on Windows)
# Verify: user can type commands and see output
# No console flicker before terminal opens
```

### Test 6: Menu is O(1) lookup
```rust
// Inspect source code: src-tauri/src/tray_menu.rs
// Verify: stage_visibility() is a simple table lookup (not conditional logic)
// Expected: fn stage_visibility(stage: Stage, item: MenuItem) -> bool { VISIBILITY_TABLE[stage][item] }
```

---

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Windows CREATE_NO_WINDOW flag, platform-specific CLI patterns
- `cheatsheets/runtime/cross-platform-terminal-launch.md` — Terminal launch on macOS (Terminal.app), Linux (GNOME Terminal, Konsole), Windows (cmd.exe)
- `cheatsheets/architecture/event-driven-ui-updates.md` — UI state machines, menu lifecycle, atomic updates

---

## Implementation References

- **Windows process spawning**: `crates/tillandsias-podman/src/lib.rs` → `CREATE_NO_WINDOW` flag on background operations
- **Interactive terminal launch**: `src-tauri/src/runner.rs` → raw `Command::new()` for interactive `podman run -it`
- **Menu state machine**: `src-tauri/src/tray_menu.rs` → `Stage` enum, visibility table, `set_stage()`
- **Menu item handlers**: `src-tauri/src/menu.rs` → menu builder (legacy reference); superseded by `tray_menu.rs`
- **Terminal platform selection**: `src-tauri/src/terminal.rs` → platform-specific terminal launcher


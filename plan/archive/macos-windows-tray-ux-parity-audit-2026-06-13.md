# macOS and Windows Tray UX Parity Audit (vs Linux Golden UX)

**Date**: 2026-06-13

## Objective
Do a massive audit of the macOS (and Windows) tray UX implementation against the Linux tray implementation ("Golden UX"). The goal is to ensure all platforms map UX features, items, and behaviors identically at all steps, with the only exception being the additional WSL2/macOS VM startup sequence step.

## Findings: Divergence from Golden UX

The Linux tray UX is implemented natively in `crates/tillandsias-headless/src/tray/mod.rs`. The macOS and Windows trays currently consume a shared, portable `MenuStructure` defined in `crates/tillandsias-host-shell/src/menu_state.rs`. This portable structure has severely drifted from the Linux implementation.

### 1. Per-Project Submenu Structure
*   **Linux (Golden):** Each project under the `~/src` and `Cloud` submenus expands into a 6-leaf flat menu offering direct tools: `Claude`, `Codex`, `OpenCode`, `OpenCode Web`, `Observatorium`, and `Maintenance`.
*   **macOS/Windows:** Each project submenu only provides `Attach Here` and `Maintenance`. The agents (`Claude`, `Codex`, `OpenCode`) are incorrectly placed in a global `Agents` picker submenu, while `Observatorium` and `OpenCode Web` are placed as global root-level menu items.
*   **Action:** Refactor `MenuStructure` to construct the 6-leaf per-project submenus and remove the global `Agents`, `Observatorium`, and `OpenCode Web` items.
*   **Status:** DONE. `MenuStructure` now embeds the tools natively within the project submenus.

### 2. GitHub Login Visibility and Exclusivity
*   **Linux (Golden):** Mutually exclusive rendering. If unauthenticated, it shows the `GitHubLogin` leaf and HIDES the project submenus. Once authenticated, it HIDES the `GitHubLogin` leaf completely and reveals the `~/src` and `Cloud` submenus.
*   **macOS/Windows:** Always renders the `GitHub Login` leaf (changing it to a disabled `GitHub: <user>` when logged in) and always renders the project submenus.
*   **Action:** Update `menu_state.rs` to enforce the mutually exclusive visibility logic for GitHub auth.
*   **Status:** DONE. Auth-gated logic ensures project submenus are hidden when logged out, and GitHub Login is hidden when logged in.

### 3. Menu Separators
*   **Linux (Golden):** Uses a clean separator (`build_separator_item`) between the dynamic content and the static footer (`Version` / `Quit`).
*   **macOS/Windows:** `menu_state.rs` omits the separator entirely.
*   **Action:** Add a separator item type to `MenuItem` and emit it before the footer.
*   **Status:** DONE. A `MenuItem::Separator` has been introduced and rendered before the footer.

### 4. Startup Sequence (WSL2/macOS VM Step)
*   **Linux (Golden):** Progresses through `PreLaunch` (Verifying environment...) -> `NetworkUp` -> `ProxyStarting` -> `GitStarting` -> `InferenceStarting` -> `ForgeStarting` -> `RouterStarting` -> `AllReady`.
*   **macOS/Windows:** Needs to incorporate the identical emoji-stacking UX progression, with one additional platform-specific step at the very beginning (e.g., `Setting up Fedora Linux...` for the VZ / WSL2 boot) before handing over to the headless runtime's pipeline.
*   **Action:** Ensure the cross-platform trays render the exact emoji stack and status text, adapting only the initial VM boot phase.
*   **Status:** DONE. `vm_phase_status_text` now returns the exact `AllReady`, `PreLaunch`, and `ShuttingDown` Unicode/emoji strings used by the Linux tray, accurately matching the Golden UX while preserving the platform-specific pre-boot phase.

## Next Steps
1. Refactor `crates/tillandsias-host-shell/src/menu_state.rs` to output a `MenuStructure` that is 1:1 identical to `crates/tillandsias-headless/src/tray/mod.rs`.
2. Update the macOS and Windows tray backend renderers to support any new `MenuItem` types (e.g., Separators).
3. Ensure the startup sequence phase strings match the cumulative emoji stack from Linux.

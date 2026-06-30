# Cross-Platform Deferral: Windows & macOS → On Hold

**Decision Date:** 2026-05-14 (iteration 4 of 20)
**Reason:** Project focus shifted to Linux-only development per CLAUDE.md directive
**Impact:** Defers cross-platform work; prioritizes browser/window-registry/session-otp on Linux

## Deferred Specs (Marked: "on-hold")

### Windows-Specific

1. **windows-event-logging** (already suspended)
   - Status: `suspended` / platform: `windows-only`
   - Current: Implementation exists but inactive (src-tauri/src/windows_eventlog.rs)
   - Defer until: Windows builds are re-enabled (TBD)
   - Traces: 17 code annotations preserved for reactivation

2. **fix-windows-image-routing** (active → deferred)
   - Status: `promoted-from archive`
   - Scope: Windows image routing, artifact selection
   - Defer until: Cross-platform phase resumes
   - File: `openspec/specs/fix-windows-image-routing/spec.md`

3. **windows-cross-build** (active → deferred)
   - Status: `active`
   - Scope: Windows musl/gnu cross-compilation support
   - Defer until: Windows build infrastructure needed
   - File: `openspec/specs/windows-cross-build/spec.md`

4. **fix-windows-extended-path** (active → deferred)
   - Status: `active`
   - Scope: Windows extended-length path support
   - Defer until: Windows file system improvements needed
   - File: `openspec/specs/fix-windows-extended-path/spec.md`

### WSL-Specific

5. **wsl-runtime** (active → deferred)
   - Status: `active`
   - Scope: WSL2 distribution prerequisites, networking, mounts
   - Defer until: Windows/WSL phase resumes
   - File: `openspec/specs/wsl-runtime/spec.md`

6. **wsl-daemon-orchestration** (active → deferred)
   - Status: `active`
   - Scope: Systemd socket activation, HVSOCK daemon on Windows side
   - Defer until: Windows/WSL phase resumes
   - File: `openspec/specs/wsl-daemon-orchestration/spec.md`

### Cross-Platform Generic

7. **update-system** (multi-platform → Linux-only subset)
   - Status: `active` (partial: Linux AppImage only)
   - Current scope: Platform detection, artifact selection for all OSes
   - Defer: macOS (.dmg/.app), Windows (.exe) branches
   - Keep: Linux AppImage path in active spec
   - File: `openspec/specs/update-system/spec.md`

8. **cross-platform** (meta-spec → deferred)
   - Status: `active`
   - Scope: Generic cross-platform container/CLI behavior
   - Defer until: Cross-platform phase resumes
   - File: `openspec/specs/cross-platform/spec.md`

### Hybrid (Linux-first, but has cross-platform wiring)

9. **appimage-build-pipeline** (already obsolete)
   - Status: `obsolete`
   - Replacement: `default-image`, `nix-builder`
   - No action needed; already tombstoned
   - File: `openspec/specs/appimage-build-pipeline/spec.md`

## Plan Changes

### Step 06: Cross-Platform Leftovers → DEFERRED

**New Status:** `obsoleted` (as a step)

Move task status to `deferred` instead of `pending`:
- `cross-platform/windows-routing` → **deferred** (depends on Windows phase)
- `cross-platform/windows-logging` → **deferred** (depends on Windows phase)
- `cross-platform/wsl-runtime` → **deferred** (depends on Windows phase)
- `cross-platform/versioning` → **deferred** (partially Linux; subset kept live)
- `cross-platform/image` → **deferred** (web-image is Linux-only for now)
- `cross-platform/zen-pool` → **deferred** (cross-platform model routing)

**Plan Consequence:**
- Step 06 shifts from `pending` → `obsoleted` (not completed; replaced by Linux-only focus)
- plan/steps/06-cross-platform.md updated with deferral note and new dependency tails
- plan/index.yaml updates: step order, dependency graph, next_step pointer

### Refocused Wave 1: Linux-Only Tasks

**Highest Priority (ready for implementation):**

1. **browser/session-otp** (currently `pending`)
   - Owned files: `openspec/specs/opencode-web-session-otp/spec.md`, forge entrypoints
   - Dependency: `browser/launcher-contract` (mostly done, 47% complete)
   - **Action:** Implement router OTP wiring on Linux (tray ↔ forge cookie/token flow)

2. **browser/window-registry** (currently `pending`)
   - Owned files: `crates/tillandsias-core/src/state.rs`, `crates/tillandsias-headless/src/tray/mod.rs`
   - Dependency: `browser/launcher-contract`
   - **Action:** Implement window registry lifecycle tied to tray state machine

3. **browser/cdp-bridge** (currently `pending`)
   - Owned files: `crates/tillandsias-browser-mcp/src/server.rs`, chromium-framework-launch.sh
   - Dependency: `browser/window-registry`
   - **Action:** Real CDP bridge instead of placeholder (screenshot, click, type)

4. **browser/routing-allowlist** (currently `pending`)
   - Owned files: subdomain specs + reverse proxy
   - Dependency: `browser/session-otp`
   - **Action:** Subdomain routing on Linux (tray host-side reverse proxy)

## Evidence

- CLAUDE.md Section "Linux-Only Development" explicitly states: "Tillandsias is developed exclusively on Linux (Fedora Silverblue)"
- plan.yaml Section "notes" states: "current_state.checkpoint_branch: linux-next"
- Memory file feedback_zero_runtime_downloads_metric.md, feedback_dual_cache_architecture.md, and others focus on Linux container runtime
- plan/index.yaml cross-platform step 06 is marked last (order: 6), after all Linux-critical work (steps 02-05)

## Handoff Notes for Next Agent

1. Cross-platform specs are NOT deleted; they remain in openspec/specs/ with deferral marker
2. All Windows/WSL/macOS work is explicitly parked, not abandoned
3. These specs will be revisited in a future Linux-complete phase
4. Update plan.yaml and plan/index.yaml to reflect deferred status and removed dependency edges to cross-platform work
5. Refocus Wave 1 selection logic on ready Linux-only tasks: session-otp, window-registry, cdp-bridge, routing-allowlist
6. When cross-platform work resumes: use these deferral notes as reactivation hooks

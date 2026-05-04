# Implementation Tasks: Codex Tray Launcher

This document tracks the implementation steps for adding Codex agent to the tray menu.

## Task List

### Phase 1: Menu Button Integration

- [x] **Task 1.1**: Add Codex button to menu.rs
  - Modify `src-tauri/src/menu.rs` to add 🏗 Codex button
  - Position: after Claude button, before Terminal button
  - Label: "🏗 Codex"
  - Wire button click to handlers::launch_codex_container()
  - Add @trace annotation: `// @trace spec:codex-tray-launcher, spec:tray-app`
  - Test: Menu renders with Codex button, button position is correct

- [x] **Task 1.2**: Implement menu button state management
  - Button is enabled when forge image is available
  - Button is disabled (grayed out) when forge is missing
  - Tooltip shows "Forge unavailable" when disabled
  - Wire to existing forge availability check logic

### Phase 2: Container Launch Handler

- [x] **Task 2.1**: Create launch_codex_container() handler (STUB)
  - Modify `src-tauri/src/handlers.rs` to add new handler ✓
  - Follow pattern from handlers::launch_claude_container() ✓
  - Container name: `tillandsias-<project>-codex` (will be done once Codex entrypoint added)
  - Network: Join enclave (proxy, git service, inference) ✓
  - Security flags: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm` ✓
  - Entrypoint: Codex binary (PATH TBD - blocked on Phase 4: forge image)
  - Add @trace annotation: `// @trace spec:codex-tray-launcher, spec:codex-container-image` ✓
  - Error handling: Show error in progress chip if launch fails ✓

- [~] **Task 2.2**: Implement progress chip display (USES EXISTING INFRA)
  - Add progress chip: "🏗 Codex — <project>" (existing infrastructure supports)
  - Color: yellow while launching, green when ready (existing infrastructure)
  - Interact: Click chip to view logs or stop container (existing infrastructure)
  - Wire to existing progress chip lifecycle (tray_state.active_builds) (existing infrastructure)

- [~] **Task 2.3**: Wire stdout/stderr to tray logs (USES EXISTING INFRA)
  - Pipe container output with `[codex]` prefix (existing infrastructure)
  - Add to tray log view (existing infrastructure)
  - Enable log filtering by source (codex vs claude vs opencode) (existing infrastructure)

### Phase 3: Container Lifecycle Management

- [ ] **Task 3.1**: Implement stop handler for Codex container
  - Progress chip "Stop" action triggers SIGTERM
  - Wait 5 seconds, then SIGKILL if needed
  - Chip transitions to gray and disappears after 2 seconds

- [ ] **Task 3.2**: Implement destroy handler for Codex container
  - Progress chip "Destroy" action removes container
  - Warn user: "Uncommitted work in container will be lost"
  - Clean up ephemeral state
  - Chip disappears

- [ ] **Task 3.3**: Implement reattach logic
  - If Codex container already running, attach instead of creating new one
  - Highlight existing progress chip
  - Show "Already running" tooltip

### Phase 4: Forge Image Integration

- [ ] **Task 4.1**: Add Codex to forge image build
  - Modify `flake.nix` to include Codex in cold layer
  - Add Codex binary to `/opt/codex` or equivalent path
  - Include dependencies and runtime libraries
  - Build and test: `scripts/build-image.sh forge`
  - Verify: Image size increase ≤ 100 MB, build time increase ≤ 5 min

- [ ] **Task 4.2**: Verify Codex in forge entrypoint
  - Test Codex launch in container: `podman run tillandsias-forge codex --help`
  - Ensure no runtime pulls required
  - Confirm binary is discoverable in PATH

### Phase 5: Network and Egress

- [ ] **Task 5.1**: Configure proxy allowlist for Codex
  - Modify proxy startup logic to add Codex allowlist rules
  - Permitted domains:
    - `api.github.com` (GitHub API)
    - `pypi.org`, `files.pythonhosted.org` (Python packages)
    - Custom code analysis service endpoints (if configured)
  - Add @trace annotation: `// @trace spec:enclave-network, spec:proxy-egress-allowlist`
  - Test: Codex can reach GitHub API, blocked from reaching other containers

- [ ] **Task 5.2**: Test egress isolation
  - Verify Codex cannot reach forge containers or host
  - Verify Codex cannot access forge container credentials
  - Confirm proxy logging shows Codex requests and allowlist decisions

### Phase 6: Testing and Verification

- [ ] **Task 6.1**: Unit tests for menu button logic
  - Test: Button renders with correct label and icon
  - Test: Button state (enabled/disabled) matches forge availability
  - Test: Button click triggers handler

- [ ] **Task 6.2**: Integration tests for container launch
  - Test: Codex container launches successfully
  - Test: Container name follows convention
  - Test: Container joins enclave network
  - Test: Output is piped to tray logs with [codex] prefix

- [ ] **Task 6.3**: Integration tests for lifecycle management
  - Test: Stop handler gracefully terminates container
  - Test: Destroy handler removes container
  - Test: Reattach logic works for existing container

- [ ] **Task 6.4**: End-to-end feature test
  - Launch Codex from menu
  - Verify progress chip appears with correct icon and label
  - Verify tray icon changes to 🔄 (working)
  - Wait for ready state (green chip, 🌟 icon)
  - Verify stdout/stderr in tray logs
  - Stop container and verify cleanup
  - Test reattach by clicking again

### Phase 7: Documentation and Compliance

- [ ] **Task 7.1**: Add @trace annotations to all code
  - Ensure all new/modified code includes @trace spec:codex-tray-launcher or related spec
  - Check: handlers.rs, menu.rs, container_profile.rs, proxy config

- [ ] **Task 7.2**: Update TRACES.md
  - Run `scripts/regenerate-traces.sh` to sync @trace annotations to TRACES.md
  - Verify all new traces appear in project trace index

- [ ] **Task 7.3**: Document Codex entrypoint in cheatsheet
  - Add entry to `cheatsheets/runtime/agent-entrypoints.md`
  - Document: Codex binary path, entrypoint behavior, required environment variables

## Implementation Order

**Recommended sequence**:
1. Phase 4 (Forge) — Build image with Codex first (takes time)
2. Phase 1 (Menu) — Add button while image builds
3. Phase 2 (Launch) — Implement handler
4. Phase 3 (Lifecycle) — Add lifecycle management
5. Phase 5 (Network) — Configure proxy allowlist
6. Phase 6 (Testing) — Run full test suite
7. Phase 7 (Documentation) — Final documentation and trace sync

## Success Criteria

- [ ] Menu renders Codex button for each project
- [ ] Codex button launches container successfully
- [ ] Container name follows convention (tillandsias-<project>-codex)
- [ ] Container joins enclave and can reach GitHub API via proxy
- [ ] Progress chip appears and transitions through states (yellow → green → gray)
- [ ] Output logged with [codex] prefix
- [ ] Stop and Destroy handlers work correctly
- [ ] Reattach logic works for existing containers
- [ ] All @trace annotations present and correct
- [ ] TRACES.md updated
- [ ] All tests pass (unit + integration)
- [ ] Codex feature works end-to-end

## Blockers and Dependencies

- **CRITICAL: Codex binary in image**: Phase 4 requires Codex to be baked into the forge image
  - Without this, Codex containers will fail to launch (entrypoint missing)
  - Requires Nix flake.nix modification to add Codex package or binary
  - Estimated effort: 2-4 hours for Nix integration + build time
  - Mitigation: Can create placeholder Codex script that echoes "Codex (stub)" for testing menu/handler wiring
- **Image build time**: Nix image build may take 10-15 minutes; Phase 4 is on the critical path
- **Proxy allowlist structure**: Verify existing proxy allowlist format before implementing Codex rules

## Notes

- Follow existing patterns from Claude and OpenCode container launches (reduce duplication)
- All containers use rootless podman with `--userns=keep-id`
- No credentials are passed to Codex containers; external access via proxy only
- Codex entrypoint and behavior are externally defined; this spec orchestrates launching, not implementing Codex itself

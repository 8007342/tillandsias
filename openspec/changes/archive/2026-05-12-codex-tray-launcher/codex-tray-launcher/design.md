## Context

The tray currently supports four agent buttons per project: OpenCode, OpenCode Web, Claude, and Terminal. Codex is a code analysis agent that should have the same first-class access. The platform already has:
- Container orchestration infrastructure (enclave network, proxy, git service)
- Agent state management in the tray state machine
- Menu item builder with dynamic action buttons
- Forge image pre-installation patterns for OpenCode and Claude tools

Adding Codex follows the established patterns but introduces a new agent container type.

## Goals / Non-Goals

**Goals:**
- Add 🏗 Codex button to tray menu (consistent placement with Claude)
- Launch Codex in a container with proxy, git mirror, and inference access (via enclave)
- Pre-install Codex binary/tooling in the forge image
- Allowlist Codex egress for any external dependencies (code repositories, analysis services)
- Provide user feedback during Codex launch (progress chips, tray icon state)
- Support multiple concurrent Codex instances (one per project)

**Non-Goals:**
- Creating a dedicated Codex image (uses forge with Codex pre-installed)
- Implementing Codex itself (assume it exists and can run in the forge)
- Adding Codex to OpenCode Web browser isolation (desktop app only)
- Building a Codex-specific UI panel (uses terminal/stdio output)

## Decisions

### 1. Menu Button Placement and Labeling
**Decision:** Add 🏗 Codex button immediately after Claude, before Terminal.
- **Rationale:** Keeps agent actions grouped (OpenCode, OpenCode Web, Claude, Codex) before utility actions (Terminal, Serve).
- **Why not inline with Claude?** Separate button allows independent lifecycle management (can run multiple agents).
- **Why 🏗?** Represents "building/analyzing code" — distinct from 👾 Claude (thinking) and 🌐 OpenCode (web IDE).

### 2. Container Lifecycle and Orchestration
**Decision:** Codex launches in a new container on the same enclave network as Claude/OpenCode.
- **Pattern:** Follows `handlers::launch_claude_container()` pattern.
- **Container name:** `tillandsias-<project>-codex` (consistent with OpenCode `tillandsias-<project>-opencode-web`).
- **Networking:** Joins the enclave; accesses proxy (for external code repos), git service (for project mirroring), inference (for LLM analysis if needed).
- **Why not reuse forge container?** Codex may need different entrypoint and config than the standard forge; isolation prevents conflicts.
- **Fallback if launch fails:** Show error in progress chip + tray log; user can retry.

### 3. Codex Pre-installation in Forge
**Decision:** Codex binary/tooling is baked into the forge image via the "cold layer" (Nix build).
- **Rationale:** 
  - Codex is a core tool (like OpenCode, Claude tools).
  - Pre-installation means no runtime pull → instant launch.
  - Avoids double-fetching (proxy + Codex's own HTTP calls).
- **How:** Add codex to `images/default/Containerfile` or Nix flake under "baked tools."
- **Image size impact:** ~50-100 MB estimated; acceptable given other tools' sizes.
- **Alternative considered:** Pull Codex at runtime from a registry (rejected: adds startup latency, requires egress allowlist).

### 4. Egress Allowlist Configuration
**Decision:** Codex is allowed outbound access to:
- PyPI (if Codex uses Python dependencies)
- GitHub API (for repository analysis)
- Cloud code analysis services (if configured by user)
- Custom git hosts (depending on project's `remoteUrl`)

**Implementation:** Proxy allowlist in tray's proxy startup logic (add codex-specific rules).

**Why:** Codex needs external connectivity to fetch code, resolve dependencies, and call analysis APIs. Proxy intercepts and allowlists; forge has zero external access.

### 5. State Management and Progress Feedback
**Decision:** Codex container state is tracked in `tray_state.active_builds` with a build progress chip.
- **Chip display:** "🏗 Codex — <project>" while launching/running.
- **Color coding:** Yellow (launching) → Green (ready) → Gray (stopped).
- **User interaction:** Click chip to see logs or stop the container.
- **Why:** Consistent with OpenCode Web and Claude container visualization.

### 6. Terminal Integration
**Decision:** Codex runs in a dedicated container with stdio attached to the tray's logs output.
- **stdout/stderr:** Piped to tray log with `[codex]` prefix for easy filtering.
- **User interaction:** User can view logs in the tray UI or SSH into the container for interactive sessions.
- **Why:** Keeps Codex output visible but separate from other agents.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| **Forge image bloat** — Adding Codex increases build time and image size. | Monitor build time; defer heavy dependencies to lazy-pull if size exceeds 500 MB total. |
| **Concurrency conflicts** — Multiple projects launching Codex simultaneously stalls the build queue. | Queue container launches via `build_lock.rs`; same as Claude/OpenCode. |
| **Proxy allowlist too permissive** — Codex egress allowlist is broad (GitHub, PyPI); could be abused. | Review allowlist quarterly; log all egress attempts for auditing. |
| **Codex binary compatibility** — Codex may not run in our forge environment (different distro, missing deps). | Test Codex launch in Alpine/Fedora containers before landing; consider multi-stage build if needed. |
| **Menu space on small screens** — Menu now has 6 buttons (OpenCode, OpenCode Web, Claude, Codex, Terminal, Serve). May wrap or get truncated. | Add submenu grouping if menu exceeds 5 items; defer "Serve" to submenu if needed. |

## Migration Plan

1. **Phase 1 (this change):** 
   - Add Codex binary to forge image.
   - Implement Codex menu button and launch handler.
   - Wire proxy allowlist.

2. **Phase 2 (future):**
   - Integrate Codex output into a dedicated UI panel (if needed).
   - Add Codex-specific configuration (analysis rules, API keys).
   - Create Codex litmus tests.

3. **Rollback:** Remove Codex button from menu; don't rebuild forge image (old forge still has Codex, no harm).

## Open Questions

1. **Does Codex need a separate container, or can it run in the forge alongside OpenCode?**
   - Assumption: Separate container (cleaner isolation, independent lifecycle).
   - Verify: Check Codex's system requirements and runtime conflicts.

2. **What external services does Codex actually need access to?**
   - Assumption: GitHub API, PyPI, maybe code analysis backends.
   - Action: Review Codex documentation; confirm egress rules before landing.

3. **How large is the Codex binary? Does it fit in a 500 MB forge image target?**
   - Assumption: ~50-100 MB.
   - Verify: Build and check image size.

4. **Should Codex support "Debug" mode (like OpenCode Web) for direct browser inspection?**
   - Assumption: No (Codex is CLI-first, outputs to logs).
   - Confirm: Clarify with Codex feature set.

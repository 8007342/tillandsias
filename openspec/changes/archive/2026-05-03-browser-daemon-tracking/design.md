## Context

The browser isolation feature (wave 3, change `design-chromium-browser-isolation`) introduced ephemeral Chromium containers with `tillandsias-chromium:latest` image. The MCP server (`tillandsias-mcp-browser`) was implemented as a persistent daemon inside the forge container, and `chromium_launcher.rs` spawns containers via `launch-chromium.sh`.

Current state gaps:
- Browser containers not tracked in `TrayState.running` → no cleanup on "Stop Project" or tray shutdown
- No debouncing → rapid-fire `open_safe_window` calls spawn multiple containers
- No user feedback → silent failures, no tray indication
- MCP server is a persistent daemon → unnecessary complexity, agents just need an on-demand tool
- OpenCode web (`opencode.<project>.localhost`) should always open in a safe browser
- Debug browsers limited to one per project (port 9222 sharing)

## Goals / Non-Goals

**Goals:**
- Track browser containers in `TrayState` with `ContainerType::Browser`
- Implement per-project debouncing (10s) for `open_safe_window` calls
- Add tray notifications: withered icon + chip for launch status (`🌐 Launching...` → `🌐 Browser launched` or `🌐 Failed`)
- Convert MCP tool from persistent daemon to on-demand binary (`tillandsias-browser-tool`)
- Always open `opencode.<project>.localhost` in safe browser
- Limit debug browsers to one per project
- Ensure browser containers terminate on tray shutdown

**Non-Goals:**
- Multiple debug browser windows (deferred — requires port/socket sharing)
- Browser DevTools access for safe windows (by design, they have no DevTools)
- Cross-project browser management (each project manages its own)

## Decisions

### Decision 1: Track browser containers in `TrayState`
**Choice**: Add `ContainerType::Browser` variant, track in `running` vec with 170XX port allocation.

**Rationale**: Consistent with forge/git/proxy tracking. Enables "Stop Project" cleanup and tray shutdown cleanup.

**Alternatives considered**:
- Track in separate `browser_containers: HashMap<project, Vec<container>>` → more complex, no shutdown integration
- Don't track (ephemeral with `--rm`) → can't show status, can't cleanup

### Decision 2: Debouncing via `tokio::time::Instant` per project
**Choice**: Store `last_browser_launch: HashMap<String, Instant>` in `TrayState`. Check + update on each `OpenBrowserWindow` command.

**Rationale**: Simple, no extra channels/tasks. 10s window prevents rapid-fire spawns from agents.

**Alternatives considered**:
- Debounce in MCP tool (Rust binary) → wrong layer, agent can bypass
- Use `tokio::sync::Semaphore` → overkill for simple rate limiting

### Decision 3: Tray notifications via withered icon + chip
**Choice**: Use existing `BuildProgress` pattern — withered globe icon + chip in menu showing `🌐 Launching browser...`. On completion: `🌐 Browser launched` (green) or `🌐 Failed` (red, 5s fadeout).

**Rationale**: Consistent with existing build progress UI. Minimal new code.

**Alternatives considered**:
- Desktop notifications (`send_notification`) → intrusive, agent context lost
- Modal dialog → too heavy for background browser spawns

### Decision 4: MCP tool as on-demand binary (not daemon)
**Choice**: Replace `tillandsias-mcp-browser` daemon with `tillandsias-browser-tool` — a simple CLI tool that:
1. Takes args: `safe <url>` or `debug <url>`
2. Connects to `/run/tillandsias/tray.sock`
3. Sends JSON-RPC request
4. Exits with status code (0 = success, 1 = failure)

**Rationale**: Agents don't need a persistent MCP server — they just need to call a tool and get success/failure. Simpler, no daemon lifecycle management.

**Alternatives considered**:
- Keep as MCP daemon → complex, requires supervision, no benefit for simple spawn use case
- Direct podman calls from agent → breaks isolation, bypasses tray validation

### Decision 5: OpenCode always uses safe browser
**Choice**: In `entrypoint-forge-opencode-web.sh`, set `OPencode_BROWSER=safe` environment variable. The `opencode serve` UI respects this and calls `tillandsias-browser-tool safe opencode.<project>.localhost`.

**Rationale**: OpenCode web UI should never open debug browsers (no DevTools needed for normal use).

### Decision 6: One debug browser per project
**Choice**: Track debug browser PID in `TrayState::debug_browser_pid: HashMap<String, u32>`. Reject new debug requests if one exists for the project.

**Rationale**: Port 9222 can only be shared by one container. Multiple debug containers would conflict.

## Risks / Trade-offs

- **[Risk]** Agent bypasses debounce by calling `tillandsias-browser-tool` directly
  - **Mitigation**: Debounce is in tray (server-side), not agent-side. Agent can't bypass.

- **[Risk]** Browser container doesn't cleanup if tray crashes
  - **Mitigation**: `--rm` flag ensures container removed on exit. Tray crash = container cleanup via podman.

- **[Risk]** `tokio::time::Instant` debounce tracking lost on tray restart
  - **Mitigation**: Acceptable — tray restarts are rare, debounce is advisory.

- **[Trade-off]** On-demand tool vs. MCP daemon
  - **Pro**: Simpler, no daemon lifecycle, agent gets sync feedback (exit code)
  - **Con**: Not standard MCP protocol (but agents don't need full MCP for this use case)

## Open Questions

- Should `tillandsias-browser-tool` support stdio JSON-RPC for MCP compatibility (future-proofing)?
  - **Decision**: No — keep it simple CLI tool. If MCP needed later, wrap it.

- Should we support multiple safe browser windows per project?
  - **Decision**: Yes, with debouncing (10s). Each gets unique port in 17000-17999 range.

- Should debug browser survive tray shutdown (for debugging across sessions)?
  - **Decision**: No — debug browsers are ephemeral, die with tray.

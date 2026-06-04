# Step 29 — Agent Launch Stability & Race Condition Fixes

Status: ready
Owner: multi-host
Depends on: [build-pipeline-optimization]

## Goal
Resolve immediate crashes and race conditions in the forge-hosted agents, focusing on Claude and OpenCode Web.

## Findings (Investigator Report)
1.  **Claude Crash**:
    *   `images/default/entrypoint-forge-claude.sh` scrubs `ANTHROPIC_API_KEY` into `_CLAUDE_KEY` but fails to re-inject it before `exec`.
    *   `~/.claude/` (config/history) is not bind-mounted from the host in `main.rs`.
    *   `ncurses` and standard terminfo files are missing from the `fedora-minimal:44` base image, breaking the TUI.
2.  **OpenCode Web Race**:
    *   `wait_for_opencode_web_route` in `main.rs` uses a 10s timeout with fixed 500ms polling.
    *   The `sse-keepalive-proxy.js` returns 502 during upstream startup; the probe exhausts attempts before the server binds to its port.

## Tasks
- [ ] **Claude Fixes**:
    - [ ] Update `entrypoint-forge-claude.sh` to `export ANTHROPIC_API_KEY="$_CLAUDE_KEY"` before `exec`.
    - [ ] Add `ncurses` and `ncurses-term` to `images/default/Containerfile`.
    - [ ] Add `~/.claude` bind-mount to `build_forge_agent_run_args` in `main.rs`.
- [ ] **OpenCode Web Refactor**:
    - [ ] Increase timeout to 30s in `wait_for_opencode_web_route`.
    - [ ] Implement exponential backoff (100ms base, 2x multiplier, 2s max).
    - [ ] Treat HTTP 502 (Bad Gateway) as a retryable "starting" state.
- [ ] **Logging Improvement**:
    - [ ] Ensure agent-side stderr is correctly captured and surfaced to the host terminal or `tillandsias.log` during launch failures.

## Exit Criteria
- `Claude` launches successfully from the tray and maintains a persistent session.
- `OpenCode Web` launches and opens the host browser reliably without "Unauthorized" errors.
- No race conditions observed during full-stack agent startup.

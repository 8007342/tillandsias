# Step 29 — Agent Launch Stability & Race Condition Fixes

Status: completed
Owner: multi-host
Depends on: [build-pipeline-optimization]

## Goal
Resolve immediate crashes and race conditions in the forge-hosted agents, focusing on Claude and OpenCode Web.

## Findings (Investigator Report)
1.  **Claude Crash**:
    *   `ncurses` and standard terminfo files were missing from the `fedora-minimal:44` base image, breaking the TUI.
    *   `images/default/entrypoint-forge-claude.sh` contained dead `ANTHROPIC_API_KEY` capture/scrub logic even though forge launch correctly receives no API key.
    *   API-key reinjection and a host `~/.claude/` bind mount were rejected: both violate the authoritative `forge-offline` and `podman-secrets-integration` credential-isolation contracts.
2.  **OpenCode Web Race**:
    *   `wait_for_opencode_web_route` in `main.rs` used a 10s timeout with fixed 500ms polling.
    *   The `sse-keepalive-proxy.js` returns 502 during upstream startup; the old probe exhausted attempts before the server bound to its port.

## Tasks
- [x] **Claude Fixes**:
    - [x] Remove dead API-key capture and explicitly report the credential-free session boundary.
    - [x] Add `ncurses` and `ncurses-term` to `images/default/Containerfile`.
    - [x] Keep host `~/.claude` and `ANTHROPIC_API_KEY` outside forge, pinned by `litmus:claude-launch-stability-shape`.
- [x] **OpenCode Web Refactor**:
    - [x] Increase timeout to 30s in `wait_for_opencode_web_route`.
    - [x] Implement exponential backoff (100ms base, 2x multiplier, 2s max).
    - [x] Treat HTTP 502 (Bad Gateway) as a retryable "starting" state.
- [x] **Logging Improvement**:
    - [x] Confirm existing debug diagnostics capture and surface agent stderr during launch failures.

## Exit Criteria
- `Claude` has the required TUI runtime and launches with an intentionally ephemeral, credential-free session. Persistent host authentication is superseded by the active credential-isolation specs.
- `OpenCode Web` launches and opens the host browser reliably without "Unauthorized" errors.
- No race conditions observed during full-stack agent startup.

## Completion Evidence
- `e74ce61e` — stabilize credential-free Claude launch and add drift-protection litmus.
- `64ab348c` — add OpenCode Web exponential backoff and retryable 502 handling.
- `./build.sh --check` — PASS.
- `./scripts/run-litmus-test.sh --phase pre-build --size instant --compact` — 102/102 PASS across 87/87 active specs.

# Step 02: Browser Isolation and Secure OpenCode Web

## Status

in_progress — Waves 1–3 complete (5 of 6 tasks); routing implementation pending (Wave 4)

## Objective

Keep the browser launch path, browser MCP bridge, OTP/session security, and service routing coherent end-to-end.

## Included Specs

- `browser-isolation-core`
- `browser-isolation-framework`
- `browser-isolation-tray-integration`
- `host-browser-mcp`
- `host-chromium-on-demand`
- `chromium-safe-variant`
- `opencode-web-session-otp`
- `mcp-on-demand`
- `subdomain-naming-flip`
- `subdomain-routing-via-reverse-proxy`

## Deliverables

- A single browser/web runtime story that is safe by default.
- Any superseded browser/session behavior tombstoned instead of kept active.
- A compact litmus chain that proves the browser path without rediscovering the same routing assumptions.

## Evidence

- Tightened the browser MCP server's unknown-method response so it now reports `Method not found: <method>`, matching the spec's error-shape requirement.
- Added an explicit v1 `browser.eval` disable path in `tools/call`, returning `EVAL_DISABLED: browser.eval is disabled in v1; see follow-up change`.
- Added unit coverage for the unknown-method prefix and the disabled-eval path.
- Verified `cargo test -p tillandsias-browser-mcp` passes with 10/10 unit tests green.
- Added URL allowlist enforcement for `browser.open`, including the project-label suffix check, `opencode.` rejection, and port/userinfo validation.
- Added in-memory browser window registry, debounce tracking, `browser.open`, `browser.list_windows`, `browser.read_url`, and `browser.close` handling in the MCP server.
- Added unit coverage for allowlist accept/reject paths, open/list/close flow, and debounce reuse.
- Verified `cargo test -p tillandsias-browser-mcp` passes with 17/17 unit tests green.
- Added an OTP login HTML/data-URI helper in `tillandsias-otp` so tray-launched OpenCode Web can launch Chromium into an auto-submitting `/_auth/login` form instead of the bare app URL.
- Switched the OpenCode Web launcher to use the new data URI and updated the readiness probe to accept any real HTTP response code, including `401`, as route-ready.
- Updated the OpenCode Web browser spec test to assert the `data:text/html;base64,...` launch contract instead of the plain project URL.
- Verified `cargo test -p tillandsias-otp` passes with 18/18 unit tests green.
- Verified the focused `tillandsias-headless` OpenCode Web launch tests still pass after the launcher change.
- Added real CDP attach/watcher loop and process-exit cleanup path to browser launcher:
  - Browser container now launches in detached mode (`-d` flag) instead of blocking.
  - Added `monitor_and_cleanup_browser` async function to poll container state and perform cleanup on exit.
  - Spawns background task to monitor browser process and clean up resources.
  - Added container name `tillandsias-browser-{project_name}` to enable tracking and cleanup.
  - Updated browser spec builder to accept project name and set container name.
- Updated `opencode_web_browser_spec_is_built_with_typed_podman_flags` test to verify:
  - Container is launched detached (`-d` flag present in args).
  - Container name is set to `tillandsias-browser-visual-chess`.
- Verified `cargo test -p tillandsias-headless --features tray` passes with 19/19 unit tests and 2/2 signal handling tests green.
- Verified `cargo test -p tillandsias-otp` still passes with 18/18 unit tests green.
- Verified `cargo build -p tillandsias-headless` compiles without errors or warnings.

## Waves 1–3 Evidence (Iteration 5)

### browser/window-registry (Wave 2a)
- Implemented thread-safe `BrowserWindowRegistry` in tillandsias-core/src/state.rs.
- Added `BrowserWindowMetadata` with fields: window_id, container_id, launch_time, last_heartbeat, status.
- Added `BrowserWindowStatus` enum: Launching, Active, Closed.
- Implemented registry methods: `new()`, `register_window()`, `unregister_window()`, `get_windows()`, `update_status()`, `heartbeat()`.
- Integrated into TrayState with automatic initialization.
- Added 10 unit tests covering register/unregister, status transitions, concurrent access, error handling.
- Verified `cargo test -p tillandsias-core` passes with 124 tests, all workspace tests pass (275+), zero clippy warnings.

### browser/session-otp (Wave 2b)
- End-to-end OTP delivery path wired: tray → router sidecar → OpenCode Web.
- OTP generation via 256-bit OS CSPRNG (getrandom(2)), base64url encoding.
- Single-use enforcement via Pending → Active lifecycle tracking.
- Constant-time comparison to prevent timing attacks; zeroize on drop.
- Router sidecar HTTP validator for Caddy forward_auth integration.
- Per-window OTP and session cookie independence; multiple windows supported.
- Verified `cargo test --workspace` passes with 491 tests, zero clippy warnings.

### browser/routing-allowlist (Wave 2c Design)
- Comprehensive design document created: plan/issues/browser-routing-design.md.
- Three-layer architecture documented: forward-proxy (Squid) → reverse-proxy (Caddy) → router-sidecar.
- Architecture gaps identified: port mismatch (spec :80 vs impl :8080), Squid .localhost forwarding missing.
- Wave 3 task ordering with dependency analysis: 6 tasks prioritized by dependency.
- Security analysis: DNS rebinding, port escape, router compromise, session hijacking mitigations.
- Spec-code alignment verified (26 port references, no TODOs untagged).

### browser/cdp-bridge (Wave 3)
- Implemented complete CDP client (cdp_client.rs) with TCP connection management.
- Added `screenshot(full_page)` via Page.captureScreenshot CDP command with base64 encoding.
- Added `click(selector)` with JavaScript element finding and mouse event dispatch.
- Added `type_text(selector, text)` with focus and keyboard event dispatch.
- Integrated into MCP server: handle_browser_screenshot/click/type with WindowRegistry lookup.
- Proper error handling: 9 error variants covering connection, selector, element-not-found scenarios.
- Comprehensive unit tests: 8 CDP client tests + 18 server handler tests; 40/40 passing.
- Verified `cargo test -p tillandsias-browser-mcp` passes with zero clippy warnings.
- Enables agents in forge containers to programmatically interact with browser windows.

## Remaining Work

- `browser.screenshot`, `browser.click`, and `browser.type` still need the real CDP bridge instead of the current follow-up placeholders.
- browser/cdp-bridge task (depends on window-registry, pending).
- browser/legacy-session-tombstone task (depends on routing-allowlist, pending).
- The step still needs the broader browser/security litmus chain once routing is implemented end-to-end.
- Wave 3: Implement browser routing (6 tasks, order documented in routing-design.md).

## Verification

- Narrow litmus for the browser/web bundle.
- `./build.sh --ci --strict --filter <browser-bundle>`
- `./build.sh --ci-full --install --strict --filter <browser-bundle>`
- `cargo test -p tillandsias-otp`
- `cargo test -p tillandsias-headless --features tray tests::opencode_web_browser_spec_is_built_with_typed_podman_flags -- --exact`
- `cargo test -p tillandsias-headless --features tray tray::tests::launch_command_opencode_web_is_detached_and_persistent -- --exact`
- `cargo test -p tillandsias-headless --features tray tray::tests::project_menu_only_shows_stop_when_web_is_running -- --exact`

## Clarification Rule

- If browser routing or session ownership is ambiguous, write the exact decision question into this step file and park only the affected spec, not the whole browser workstream.

## Granular Tasks

- `browser/launcher-contract`
- `browser/window-registry`
- `browser/cdp-bridge`
- `browser/session-otp`
- `browser/routing-allowlist`
- `browser/legacy-session-tombstone`

## Handoff

- Assume the next agent may be different.
- Record the current branch, file scope, residual risk, checkpoint SHA, and dependency tail in any progress note.
- Repeating the same update should be harmless if the same task ID and update ID are applied again.

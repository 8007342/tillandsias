# Step 02: Browser Isolation and Secure OpenCode Web

## Status

in_progress

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

## Remaining Work

- `browser.screenshot`, `browser.click`, and `browser.type` still need the real CDP bridge instead of the current follow-up placeholders.
- The launcher still needs a real CDP attach/watcher loop and process-exit cleanup path to satisfy the full window-lifecycle contract.
- The step still needs the broader browser/security litmus chain once the runtime path is implemented end-to-end.

## Verification

- Narrow litmus for the browser/web bundle.
- `./build.sh --ci --strict --filter <browser-bundle>`
- `./build.sh --ci-full --install --strict --filter <browser-bundle>`

## Clarification Rule

- If browser routing or session ownership is ambiguous, write the exact decision question into this step file and park only the affected spec, not the whole browser workstream.

## Granular Tasks

- `browser/launch-path`
- `browser/mcp-bridge`
- `browser/session-otp`
- `browser/legacy-session-tombstone`

## Handoff

- Assume the next agent may be different.
- Record the current branch, file scope, residual risk, checkpoint SHA, and dependency tail in any progress note.
- Repeating the same update should be harmless if the same task ID and update ID are applied again.

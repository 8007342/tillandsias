## Why

Multiple in-flight changes need an out-of-band channel between tray-side processes and tray-spawned containers (router for OTP transport per `opencode-web-session-otp`; future host MCP server for browser-open allowlist; future cross-process events). Each ad-hoc design adds attack surface. One reviewable Unix-socket control plane is the smallest defensible shape.

## What Changes

- **NEW** `tray-host-control-socket` Rust library + tray-side server. Listens on `/run/user/<uid>/tillandsias/control.sock` (mode 0600).
- **NEW** Wire format: postcard-framed messages per the project's `feedback_design_philosophy` rule (no JSON in hot paths). Each message is a length-prefixed postcard envelope.
- **NEW** Helper client crate so consumers (router sidecar, browser MCP, future control-plane callers) just import + send typed messages.
- **NEW** Capability-based message routing: each consumer registers a typed channel (`enum ControlMessage::Otp(...) | ::OpenBrowser(...) | ...`) so dispatch is O(1) and unauthorised messages are rejected at deserialise time.
- Lifetime: socket created on tray start, removed on Quit (after `shutdown_all`). Stale-socket detection on next start (unlink if no active listener).

## Capabilities

### New Capabilities
- `tray-host-control-socket`: Unix-socket protocol + framing + message types + lifetime contract.

### Modified Capabilities
- (none — strictly additive infrastructure)

## Impact

- New crate `crates/tillandsias-control-socket` — ~300 LOC server + ~150 LOC client.
- Tray binary spawns the socket server at startup; tears down on shutdown.
- Existing changes that need the socket get added as message variants in dependency order: OTP (`opencode-web-session-otp`) first, then browser-open MCP (`host-browser-mcp`).
- Zero new UX. Zero new prompts.

## Sources of Truth

- (Host memory) `feedback_design_philosophy` — no JSON for IPC; postcard for internal.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the socket lives at `/run/user/<uid>/` (XDG runtime), ephemeral by design.

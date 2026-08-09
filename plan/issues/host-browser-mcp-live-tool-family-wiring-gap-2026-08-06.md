# Configured host-browser MCP does not expose the browser tool family

Date: 2026-08-06 (America/Los_Angeles)
Status: ready
Plan: `host-browser-mcp-live-tool-family-wiring-gap` (order 616-nm7q)
Release: v0.5

## Finding

The forge's active OpenCode/Claude configuration launches
`images/default/config-overlay/mcp/host-browser.sh`. That script is a real
stdio-to-control-socket bridge, but its `McpFrame` requests terminate in
`crates/tillandsias-headless/src/tray/mod.rs::handle_mcp_jsonrpc`. The current
handler advertises exactly:

- `publish_local`;
- `service_status`; and
- `service_stop`.

The separate `tillandsias-browser-mcp` crate implements and tests eight
`browser.*` tools, but `cargo metadata` shows no production binary target and no
other crate links the library. Nothing on the configured bridge dispatches to
its server.

There is a second, builder-specific break at the Nix packaging seam. The Fedora
`images/default/Containerfile` copies the rich OpenCode config and
`config-overlay/mcp/` directory, so its `host-browser.sh` route remains present
after 606-3e2u removes the dead artifacts. In contrast, `flake.nix` binds
`forgeOpencode = ./images/default/opencode.json`, where that JSON is only a
schema/autoupdate stub, and copies it solely to
`/home/forge/.config/opencode/config.json`. The Nix image never installs
`config-overlay/opencode/config.json`, `config-overlay/mcp/host-browser.sh`, or
`config-overlay/claude/mcp.json`. After the opaque ELF is deleted, a Nix-built
forge therefore has no configured host-browser MCP route at all.

This contradicts active `host-browser-mcp` spec text and its litmus description,
which claim that `tools/list` returns eight browser tools and that browser open,
screenshot, click, type, and close work through this route. Current unit gates
test the browser library in isolation and the three-tool control handler
separately; both can be green while the configured product surface lacks every
browser tool.

## Relationship to stale artifacts

Order 606-3e2u owns deletion of the unreachable mock JS and opaque 27.2 MB x86
ELF. Those files are not a viable wiring path and must not be retained to hide
this gap. That cleanup leaves the Fedora source-controlled bridge intact but
also exposes the missing Nix packaging route described above. This packet owns
making the live source-built path uniform across both builders.

## Implementation boundary

Choose one explicit ownership model:

1. link the browser MCP library into the host-side control dispatcher and
   compose its eight schemas/calls with the publish/service family; or
2. expose a source-built host process whose lifecycle and control-socket route
   are installed uniformly by the supported image builders.

The first option reuses the live authenticated Unix-socket route and avoids a
second transport, but must preserve project/session attribution and the
browser allowlist. Resolve the spec's outstanding MCP-frame size mismatch for
screenshot payloads and retain the per-session concurrency limit. Do not add a
menu, label, dialog, or other user-visible UX surface.

Whichever ownership model is selected, make the Nix `forge-image` package the
same source-controlled MCP configuration and bridge as the Fedora image. The
load-bearing seam is `flake.nix`'s local-file bindings plus
`fakeRootCommands`: replace the schema-only config install with the rich
config-overlay path, install `host-browser.sh` at its configured in-image path,
install the Claude MCP manifest where its entrypoint expects it, and assert the
Nix output contains those files on x86_64 and aarch64.

## Exit contract

- A freshly launched forge calls the configured `host-browser` MCP and its
  real `tools/list` contains the eight specified `browser.*` tools with their
  closed schemas (alongside any deliberately composed publish tools).
- A product-path call crosses stdio, the Unix control socket, host dispatch,
  allowlist, browser launch, and response framing; open plus one read-only
  operation is proven without a test-only direct library call.
- Screenshot payload and 17th-concurrent-call negative fixtures exercise the
  actual transport, not only the library.
- The implementation is built from source for x86_64 and aarch64; no checked-in
  executable or mock server returns a success-shaped placeholder.
- Unknown methods/tools and disallowed URLs fail with typed JSON-RPC errors.
- No user-visible UX changes.

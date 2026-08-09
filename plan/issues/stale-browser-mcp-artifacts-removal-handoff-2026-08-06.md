# Stale browser MCP artifacts — verified removal handoff

Date: 2026-08-06 (America/Los_Angeles)
Status: ready
Plan: `stale-browser-mcp-artifacts-cleanup` (order 606-3e2u)
Release: v0.5

## Reachability verdict

Both named artifacts are dead and should be removed:

- `images/default/mcp-server-browser.js` is a 5,751-byte mock. No Containerfile,
  config, or entrypoint copies or executes it; its `forwardToTray()` still
  returns a success-shaped `{status: "queued"}` placeholder instead of
  contacting the tray.
- `images/default/tillandsias-mcp-browser` is a checked-in 27,243,632-byte,
  dynamically linked x86_64 ELF with debug information. Its original binary
  source was removed, the current `tillandsias-browser-mcp` package exposes no
  binary target, and no runtime config executes it.

The opaque ELF's only current production reference is `flake.nix`, which copies
it into the Nix forge output. That also makes the nominal aarch64 output carry
an x86_64 executable. The Fedora default image copies neither artifact.

## Exact cleanup slice

1. Delete `images/default/mcp-server-browser.js`.
2. Delete `images/default/tillandsias-mcp-browser`.
3. Remove only the `forgeMcpBrowser` binding and its copy/chmod lines from
   `flake.nix`.
4. Correct active `openspec/specs/host-browser-mcp/spec.md` text that claims the
   OpenCode Web entrypoint launches the opaque binary.
5. Resolve or archive the unarchived
   `openspec/changes/chromium-browser-isolation` design snippet that embeds the
   mock JS, using the normal OpenSpec workflow.

Keep archived browser-daemon changes, the dated browser-isolation audit, and
`build-menu-test.log` as historical provenance; they are not live consumers and
must not be rewritten as though the removed files never existed.

## Integration surface boundary

The cleanup preserves the live Fedora/config-overlay route:

- `images/default/Containerfile` copies the rich
  `config-overlay/opencode/config.json` and the `config-overlay/mcp/` directory;
- that config invokes
  `/home/forge/.config-overlay/mcp/host-browser.sh`; and
- the bridge still reaches the host socket through
  `TILLANDSIAS_CONTROL_SOCKET`.

The Nix `forge-image` does **not** package that route. Its `forgeOpencode`
binding still points at the schema-only `images/default/opencode.json`, copies
only that file to `/home/forge/.config/opencode/config.json`, and never copies
the rich config-overlay MCP directory, `host-browser.sh`, or the Claude MCP
manifest. Removing the opaque ELF therefore leaves the Nix image with no
configured host-browser MCP surface. That pre-existing packaging/wiring gap is
owned by `host-browser-mcp-live-tool-family-wiring-gap` (616-nm7q); restoring
the deleted binary is not a valid fix.

## Verification

- Add a negative source/flake fixture proving both paths and the
  `forgeMcpBrowser` binding are absent.
- Run the host-browser, on-demand bridge, and MCP discoverability litmus files,
  plus `cargo test -p tillandsias-browser-mcp` and the headless control-handler
  tests.
- Record the 27,243,632-byte checkout/output reduction and, on capable hosts,
  evaluate both x86_64 and aarch64 Nix outputs.

This host has no usable Nix daemon socket, so the remaining 606-3e2u evidence is
an x86_64 `.#forge-image` build plus an aarch64 `.#forge-image` build with each
result's exact byte/Nix closure size recorded. The source payload removed is
exactly 27,249,383 bytes (27,243,632-byte ELF + 5,751-byte mock JS); the built
output delta must still be measured rather than inferred from that source sum.

These gates prove artifact removal and preserve the configured shell/control
route. They do not prove that the eight browser tools are live: the configured
bridge currently terminates in a three-tool publish/service handler while the
browser library has no production consumer. Order 616-nm7q owns that separate
wiring gap and is not a reason to retain either stale artifact.

The two live dangling-reference surfaces were corrected: the active
`host-browser-mcp` spec now names the on-demand bridge instead of the opaque
daemon, and the unarchived Chromium design that named the mock JS was moved to
the dated OpenSpec archive. The focused `host-browser-mcp` litmus passed 2/2,
including the new negative absence fixture.

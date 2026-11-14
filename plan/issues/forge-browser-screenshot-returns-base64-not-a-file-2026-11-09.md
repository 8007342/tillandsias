# browser.screenshot returns raw base64, not a file the agent can Read (order 2065-9hfj)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e),
relayed by macuahuitl-fedora.

## What is wrong

`handle_browser_screenshot`
(crates/tillandsias-browser-mcp/src/server.rs) returns
`{"data": "<base64 PNG>"}`. An agent cannot look at that. It fills the
context with base64, and the Read tool, which displays images, needs a
path.

## Ask

Write the PNG to a forge-visible path, then return
`{"path": ..., "bytes": n, "width": w, "height": h}`. The path should be
under the session scratchpad when the caller names one, else something like
`/work/tmp/screenshots/<window>-<ts>.png`. Keep `data` only behind an
explicit `inline: true`.

## Why this is not a one-line fix

The browser MCP runs on the host side of the enclave, so it cannot write
into the forge's filesystem directly. The PNG has to travel back through the
control wire and be written forge-side, by the forge's MCP shim, or into a
host directory that is mounted into the forge. Choosing which is the work.

## Closure

From a forge, `browser.screenshot` returns a path, and `Read <path>` shows
the page.

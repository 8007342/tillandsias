<!-- @tombstone superseded:host-browser-mcp+browser-isolation-tray-integration+tray-host-control-socket -->
<!-- @trace spec:host-browser-mcp -->
# browser-mcp-server Specification

## Status

obsolete

## Purpose

Historical stub retained for traceability only. The live browser MCP server
contract now lives in `host-browser-mcp`, with transport and tray ownership
split across `tray-host-control-socket` and
`browser-isolation-tray-integration`.

## Superseded By

- `openspec/specs/host-browser-mcp/spec.md`
- `openspec/specs/tray-host-control-socket/spec.md`
- `openspec/specs/browser-isolation-tray-integration/spec.md`

## Notes

- The current implementation exposes the live browser MCP server from the tray
  process and is already traced by `host-browser-mcp`.
- This tombstone remains only so older trace links and archived discussions stay
  readable.

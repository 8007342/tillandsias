## ADDED Requirements

### Requirement: The socket carries the image tools

The per-lane MCP tool socket MUST list and dispatch `image.generate` beside
`publish_local`, `service_*` and `browser.*`, so every agent harness that
reaches the socket through the `host-browser` bridge (Claude, OpenCode,
Codex) sees the same tool with the same schema.

#### Scenario: tools/list includes image.generate
- **WHEN** a forge lane sends `tools/list` on its socket
- **THEN** the reply lists `image.generate` with its input schema

## ADDED Requirements

### Requirement: The host MCP socket carries music.* tools

The host MCP tool socket MUST list and dispatch `music.compose`,
`music.continue`, `music.stems`, `music.variations` and `music.models` to
Claude, OpenCode and Codex lanes alike, beside `image.generate`, with the
same consent-grant and licence-refusal shapes.

#### Scenario: tools/list includes the music tools
- **WHEN** a forge lane sends `tools/list`
- **THEN** the reply lists `music.compose`, `music.continue`, `music.stems`, `music.variations` and `music.models`

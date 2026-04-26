## ADDED Requirements

### Requirement: cheatsheet-mcp binary exposes five tools over stdio JSON-RPC

The `tillandsias-cheatsheet-mcp` binary SHALL implement an MCP (Model Context Protocol) server speaking stdio JSON-RPC. It SHALL expose exactly five tools:

| Tool | Args | Returns |
|---|---|---|
| `cheatsheet.search` | `query: string, max_results: int = 5, filter_category: string?` | `[{path, title, tags, score, snippet}]` ordered by descending score |
| `cheatsheet.get` | `path: string` | `{frontmatter, body}` |
| `cheatsheet.related` | `path: string, max: int = 5` | `[paths]` from the file's `## See also` block |
| `cheatsheet.list` | `category: string?, status: string?, tag: string?` | `[{path, title, status, last_verified}]` |
| `cheatsheet.stale_check` | `older_than_days: int = 90` | `[{path, last_verified, days_old}]` |

#### Scenario: search ranks tag matches above body matches
- **WHEN** the client calls `cheatsheet.search("rxjava")` against an index containing `languages/java/rxjava-event-driven.md` (with `tags: [rxjava, ...]`) AND `architecture/event-driven-basics.md` (mentions "rxjava" once in body)
- **THEN** the result SHALL list `languages/java/rxjava-event-driven.md` first (higher score from tag match)
- **AND** `architecture/event-driven-basics.md` SHALL appear after, with a lower score reflecting its body-only match

#### Scenario: get returns parsed frontmatter + body
- **WHEN** the client calls `cheatsheet.get("languages/java/rxjava-event-driven.md")`
- **THEN** the response SHALL contain `frontmatter` as a structured object (tags, languages, since, last_verified, sources, authority, status) AND `body` as the markdown content with frontmatter stripped

#### Scenario: stale_check defaults to 90 days
- **WHEN** the client calls `cheatsheet.stale_check()` with no args AND the index contains files with `last_verified` 30, 95, and 200 days old
- **THEN** the result SHALL include the 95-day and 200-day files
- **AND** the 30-day file SHALL NOT appear in the result

#### Scenario: list filters by status
- **WHEN** the client calls `cheatsheet.list(status="draft")` AND the index has 60 DRAFT files + 12 current files
- **THEN** the result SHALL contain exactly 60 entries — only the DRAFT ones

#### Scenario: search excludes deprecated by default
- **WHEN** the client calls `cheatsheet.search("foo")` AND a `deprecated`-status cheatsheet matches the query
- **THEN** the deprecated cheatsheet SHALL NOT appear in the default result
- **AND** an explicit `cheatsheet.list(status="deprecated")` call DOES surface it

### Requirement: cheatsheet-mcp ships in the forge image

The forge image SHALL bake `tillandsias-cheatsheet-mcp` at `/opt/agents/cheatsheet-mcp/bin/cheatsheet-mcp` with `+x` permissions, owned root:root, world-readable. The opencode config (`/home/forge/.config/opencode/config.json`) SHALL register it as an MCP server so agents inside the forge can call its tools without spawning anything.

#### Scenario: Binary present in forge
- **WHEN** an agent runs `which cheatsheet-mcp` inside the forge
- **THEN** the path `/opt/agents/cheatsheet-mcp/bin/cheatsheet-mcp` SHALL be returned
- **AND** running it with no args SHALL print a JSON-RPC ready message on stderr

#### Scenario: opencode auto-registers it
- **WHEN** opencode starts inside the forge
- **THEN** its config SHALL include `mcpServers: { cheatsheet: { command: "/opt/agents/cheatsheet-mcp/bin/cheatsheet-mcp" } }`
- **AND** the `cheatsheet.search` etc. tools SHALL appear in the agent's tool list

### Requirement: INDEX.md is auto-generated, not hand-edited

`cheatsheets/INDEX.md` SHALL be regenerated from cheatsheet frontmatter by `scripts/regenerate-cheatsheet-index.sh`. The file SHALL NOT be hand-edited. A header comment in INDEX.md SHALL state this. Pre-commit hook SHALL run the regeneration; manual edits get overwritten on next commit.

The regenerator SHALL emit `[DRAFT]` next to entries with `status: draft`, `[STALE]` for `status: stale`, no marker for `status: current`, and SHALL hide `status: deprecated` from the default INDEX (visible only via `cheatsheet.list(status="deprecated")` MCP call).

#### Scenario: regeneration is idempotent
- **WHEN** `scripts/regenerate-cheatsheet-index.sh` runs twice in a row with no other changes
- **THEN** the second run SHALL produce zero diff against `git status`

#### Scenario: missing frontmatter doesn't crash
- **WHEN** the regenerator encounters a `.md` file with no YAML frontmatter
- **THEN** it SHALL emit a warning naming the file AND fall back to using the filename + first H1 for the index entry
- **AND** the entry SHALL be tagged `[DRAFT]` so the gap is visible

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — the architecture
- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — the schema
- `cheatsheets/runtime/cheatsheet-shortcomings.md` — the items being closed

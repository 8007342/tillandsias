## Why

`cheatsheet-shortcomings.md` enumerated 10 first-hand gaps in the v2 cheatsheet system. 7 of them are tooling absences:

- (1) cross-references untested
- (2) INDEX.md drifts on every new file
- (3) no tag-aware search (frontmatter is YAML, grep only sees body)
- (4) provenance URLs unverified (dead links rot silently)
- (5) `last_verified` doesn't drive any visible signal
- (7) status enum has no enforcement
- (9) See-also graph not navigable both ways
- (10) host-side MCP doesn't exist (host Claude can't dogfood)

This change builds the toolchain in one focused effort. The MCP server is the centrepiece — same single-binary stdio JSON-RPC server runs on the host (for me) and inside the forge (for agents). Plus four supporting scripts that the MCP can re-use as backends or that humans can invoke directly.

## What Changes

- **NEW** `crates/tillandsias-cheatsheet-mcp` — Rust binary + library implementing an MCP server (stdio JSON-RPC) over the on-disk cheatsheet tree. Tools: `cheatsheet.search`, `cheatsheet.get`, `cheatsheet.related`, `cheatsheet.list`, `cheatsheet.stale_check`. Scope: scan `cheatsheets/<category>/<file>.md`, parse YAML frontmatter, build an in-memory index, serve queries. ≤ 1500 LOC target.
- **NEW** `scripts/regenerate-cheatsheet-index.sh` — walks `cheatsheets/`, parses frontmatter from every `.md`, regenerates `INDEX.md` from scratch with `[DRAFT]`/`[STALE]` markers based on `status:`. Idempotent. Run pre-commit.
- **NEW** `scripts/check-cheatsheet-refs.sh` — walks every `@cheatsheet path.md` annotation in code AND every `## See also` link AND every `cheatsheet=` log field; asserts each path resolves to a real file. Exits non-zero on any broken ref.
- **NEW** `scripts/check-cheatsheet-provenance-reachability.sh` — `curl -fsSI` every URL in every cheatsheet's `sources:` frontmatter list; logs 4xx/5xx/timeout. Does NOT block CI (URLs go down occasionally); writes a tracked file with the failures.
- **NEW** `scripts/check-cheatsheet-staleness.sh` — walks frontmatter, finds files with `last_verified:` more than 90 days old; prints them. Default informational; `--strict` to exit non-zero.
- **NEW** Pre-commit hook (`.git/hooks/pre-commit` or via `lefthook`/`pre-commit-config.yaml`) chains: regenerate-index → check-refs (warn-only). Provenance-reachability + staleness run on a slower cadence (weekly script-runner / CI cron).
- **MODIFIED** `cheatsheets/INDEX.md` becomes auto-generated. Manual edits get overwritten on next regen — annotation in the file header makes that explicit.
- **MODIFIED** `forge image` ships `tillandsias-cheatsheet-mcp` as a baked binary at `/opt/agents/cheatsheet-mcp/bin/` so opencode in the forge can hand off cheatsheet queries to it (and agents register it as an MCP server). Host tray also exposes a way to start the same binary from a Claude Code MCP config (out-of-band: I add `~/.claude/settings.json` mcpServers entry myself).

## Capabilities

### New Capabilities
- `cheatsheet-mcp-server`: tool definitions, query semantics, frontmatter parsing, indexing, ranking.
- `cheatsheet-tooling`: pre-commit checks (refs + index regen) and async checks (provenance + staleness).

### Modified Capabilities
- `agent-cheatsheets`: INDEX.md is auto-generated; `[DRAFT]`/`[STALE]` markers come from frontmatter `status:` field; no manual edits.
- `default-image`: forge ships `cheatsheet-mcp` binary alongside the other agent binaries at `/opt/agents/cheatsheet-mcp/`.

## Impact

- New crate `tillandsias-cheatsheet-mcp` — adds dependency on `serde_yaml` + `jsonrpc-stdio-server` (or hand-roll MCP since the protocol is small). Single-file binary ~1.5 MB stripped.
- 4 new shell scripts under `scripts/` — total < 200 LOC across all of them.
- Forge image grows by ~5 MB (the MCP binary).
- Host: I add a Claude Code MCP server entry to `~/.claude/settings.json` so I can dogfood. (Out of repo — manual user step in the migration notes.)
- INDEX.md authoring shifts from manual to script-managed — the file header notes "auto-generated, do not edit manually."
- Forge agents (opencode, claude) get an opencode MCP-server registration pointing at `/opt/agents/cheatsheet-mcp/bin/cheatsheet-mcp`. Agent prompts encourage `cheatsheet.search(...)` over raw `Read` for cheatsheet lookups.

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — the architecture this implements.
- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — the schema the parser conforms to.
- `cheatsheets/runtime/cheatsheet-shortcomings.md` — the gap list this change closes.

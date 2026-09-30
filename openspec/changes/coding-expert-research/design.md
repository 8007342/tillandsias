# Design — coding-expert-research

Umbrella packet: `1505-33dh`. Code is cited by SYMBOL. The exploration note
with the diagram and the reading list:
`plan/issues/coding-expert-research-2026-09-29.md`.

## Context

- `run_grounded` (tillandsias-plan `pipeline`) is the one function behind
  `expert-serve` and the `pipeline` CLI; it retrieves only from a published
  spec-index entry and returns an envelope or an `unsupported:` refusal.
- `spec-index` builds the index; `experts-probe` reports tier readiness;
  `corpus-coverage` names indexed and declined file types.
- `mlua` in `tillandsias-plan`: `lua_predicate` (`proc.run`, repo-rooted
  `fs.read`), `lua_std` (`json`, `yaml`, `hash`, `path`, `time`), the
  sandboxed `tillandsias-plan lua` CLI, embedded `hooks/*.lua`.
- MCP: `tillandsias-browser-mcp` (`framing`, `server`, protocol
  `2025-06-18`), the tray `mcp.sock` (`dev-control-mcp` change), shell
  servers in `.mcp.json`.
- Cheatsheets: `cheatsheets/` with `license-allowlist.toml`;
  `cheatsheet-sources/` (specs `cheatsheet-source-layer`,
  `agent-cheatsheets`).
- The git mirror container per project (`/srv/git/<project>`).

## Decision 1 — research first, with outcomes that are tokens

Each packet ends in a last stdout line `outcome:<token>` from a closed
vocabulary written in the packet before the measurement runs, plus the
regime (host, versions). A packet whose result is prose without its token is
not closed. This is the fleet's peer-falsification method: a peer can re-run
the script and get a different token, and that is a finding.

## Decision 2 — the surface is explored in two readings

- **Schema signature**: the `tools/list` entry for `write_function_for_file`
  is minted per call — input schema narrowed to one file and one function
  name, `enum`s for allowed symbols, `maxLength` for bytes. Whether a
  harness re-lists on `notifications/tools/list_changed` is measurement 1;
  if it does not, the fallback is ONE static tool with a `surface` argument
  obtained from a preceding `mint` call.
- **One-time token**: `{nonce, expires_at, affordances}` signed with a keyed
  digest (a keyed variant is added to `lua_std.hash` for the prototype) and
  spent on first use; the expert's output must carry it back unchanged.

The mint is a sandboxed Lua script (`coding_expert/mint.lua` in the
prototype path): request table in, surface table out; no `proc.run`, no
writes. Lua is chosen because the surface must be data the operator can
read and edit per project, the runtime already exists with a sandbox and
policy floor, and a Rust struct per project would put the surface in a
release.

## Decision 3 — the corpus is the mirror plus eager cheatsheets

The `code` domain indexes `/srv/git/<project>` at the mirror's integration
HEAD (a named commit in the index entry's freshness frame), never the
working tree, so every host with the same mirror state builds the same
entry and a fleet expert's citations resolve on a spoke. Cheatsheets are
loaded eagerly at index time for the technologies detected in the project
(`Cargo.toml` dependency names → Rust, tokio, mlua; `*.lua` → Lua;
`flake.nix` → nix; …), through the license allowlist, and refreshed when
the mirror moves (the `post-commit.lua` hook is the trigger to measure;
delta rebuild is the open question, with 1259-dgaq's per-model vectors as
the prerequisite reading).

## Decision 4 — one endpoint, one more domain

The Coding Expert is a `run_grounded` domain named `coding`, not a second
server: locally `tillandsias-experts/coding`, over the mesh
`tillandsias-fleet-experts/coding` (1505-br88). The MCP server is a thin
front-end that mints, calls the endpoint, verifies, and returns — the same
"one pipeline, two front-ends" rule the grounded pipeline already keeps.

## Decision 5 — the threat table is a deliverable

Replay, widening, path escape, unsolicited signing, cross-project
impersonation (the `dev-control-mcp` attribution hole), and prompt
injection through retrieved chunks each get one row: threat, mechanism,
the test the implementation must pass, and whether the nonce must be
HMAC-keyed (key in Vault) or memory-resident random.

## Risks

- A harness that ignores `list_changed` makes the dynamic schema cosmetic;
  the fallback keeps the one-time token, which is the real control.
- Eager cheatsheet loading can blow the index on a floor host; the corpus
  packet measures size and build time there first.
- A coding expert that writes code changes the safety posture of the
  grounded pipeline (it never wrote before); the security packet is gated
  ahead of any implementation packet by `depends_on`.

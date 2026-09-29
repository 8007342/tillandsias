# The CODING EXPERT: a one-method MCP with a per-call minted surface, RAG over the git mirror and eagerly loaded cheatsheets (milestone 1505-33dh)

- classification: research / design exploration (nothing implemented)
- filed: 2026-09-29 (linux/macuahuitl, design-lead session)
- status: research packets filed; desired_release v0.7 (after the v0.6
  Cloudflare/fleet milestone 1505-sm2j, which it serves through)
- change: `openspec/changes/coding-expert-research/`

## Operator intent (verbatim, 2026-09-29)

"A CODING EXPERT. An MCP server gives the agent harness ONE method,
`write_function_for_file(contents)`, whose signature and affordances are
generated dynamically per call: the MCP receives a request for a code
change, mints a ONE-TIME MCP signature + affordances (leverage the project's
embedded Lua runtime for this dynamic surface), and issues it to the Coding
Expert. The Coding Expert is RAG-enhanced with embeddings from the project's
git mirror AND from EAGERLY LOADED cheatsheets for the project's technologies
(Rust, Lua, Tokio, …), refreshed as fresh RAG. It can be served locally and
as a fleet expert."

## What exists that this builds on (read; do not re-file)

- The grounded pipeline: `tillandsias_plan::pipeline::run_grounded` is the
  ONE function behind `expert-serve` (`POST /v1/chat/completions`) and the
  `pipeline` CLI; retrieval only from a published content-addressed
  spec-index entry; typed `unsupported:` refusals; citations kept only if
  used (spec `expert-serve-grounded-pipeline`, R1/R2). Domains today: all,
  spec, code, methodology, cheatsheet (`opencode.json` models).
- The index: `tillandsias-plan spec-index` builds it; `experts-probe`
  reports l0/l1/l2 readiness (l1 needs an embeddings endpoint AND a built
  index); `corpus-coverage` says which file types are indexed and which are
  declined and why.
- Cheatsheets: `cheatsheets/` (agents, algorithms, architecture, build,
  concurrent-git, data, languages, observability, patterns, privacy, …) with
  `license-allowlist.toml`; `cheatsheet-sources/` verbatim sources with
  provenance (specs `cheatsheet-source-layer`, `agent-cheatsheets`,
  `cheatsheet-mcp-server`).
- The Lua runtime: `mlua` 0.10 (lua54, vendored, send, serialize) in
  `tillandsias-plan`; `lua_predicate` (`proc.run`, `sh.run`, repo-rooted
  `fs.read`, Observing-only write verbs), `lua_std` (`json`, `yaml`, `hash`,
  `path`, `time`), the sandboxed `tillandsias-plan lua` CLI, and the
  embedded discipline hooks (`hooks/*.lua`); the `command-runtime` /
  `command-policies` capabilities (1443-6r3q) add typed `run` doors and a
  policy floor.
- MCP in Rust: `tillandsias-browser-mcp` (`framing`, `server`; protocol
  `2025-06-18`), the tray's `mcp.sock` NDJSON socket (`dev-control-mcp`
  change specifies the transport and the per-lane attribution repair), and
  the shell MCP servers `forge-plan` / `project-info` in `.mcp.json`.
- The git mirror: `tillandsias-git-<project>` containers serving
  `/srv/git/<project>` with hooks (`publish-sync-state`,
  `reconcile-exported-heads`), the source of truth for "the project's git".
- Fleet serving (v0.6, 1505-br88): `expert-serve --bind --bearer-file`
  behind `fleet-experts.tillandsias-vpn.internal`.

## The shape under exploration

```
harness ──tools/list──▶ coding-expert MCP ──▶ exactly ONE tool:
                                              write_function_for_file
                                              (schema minted for THIS call)
harness ──tools/call──▶ mint step (Lua): reads the request (file, intent),
                        retrieves context (RAG: mirror + cheatsheets),
                        emits a ONE-TIME surface: {nonce, expires_at,
                        input schema narrowed to this file/function,
                        affordances: allowed paths, allowed symbols,
                        max bytes, required tests}
                     ──▶ Coding Expert (grounded model call through
                        run_grounded, domain "code", prompt = surface +
                        retrieved chunks) ──▶ candidate contents
                     ──▶ verifier (Lua): the candidate is accepted only if
                        it stays inside the affordances and the nonce is
                        unspent ──▶ result {contents, citations, nonce spent}
```

The "signature" the operator names is read two ways and both are explored:
(a) the JSON-Schema signature of the tool as the harness sees it, minted per
call so the harness can only ask for what the mint allowed; (b) a
cryptographic one-time token (nonce + HMAC over the affordances, spent on
use) that the expert's output must carry back, so a reply cannot be replayed
or widened. The Lua runtime is the mint: a sandboxed script
(`coding_expert/mint.lua`) receives the request as a table and returns the
surface as a table; `hash` and `json` from `lua_std` are enough for the
HMAC-shaped token if a keyed digest is added to `lua_std.hash`.

## Research questions (one packet each)

1. **Dynamic one-time MCP surface via Lua (1505-ga5f, opus).** Can an MCP
   server legally change its `tools/list` per call? MCP has
   `notifications/tools/list_changed`; the packet measures whether Claude
   Code, OpenCode and Codex re-list on that notification and what latency
   that costs, or whether the ONE static tool should carry a `surface`
   argument minted by a preceding call. Prototype the mint in Lua under the
   sandbox: input request → output surface table with nonce, expiry,
   narrowed schema, affordances. Outcome tokens: `relist-honoured`,
   `relist-ignored-static-surface-needed`, `harness-specific`.
2. **RAG corpus: git mirror + eagerly loaded cheatsheets (1505-k4xs,
   sonnet).** Extend the index build so the `code` domain embeds from the
   project's git mirror (not the working tree) at a named commit, and so the
   cheatsheets for the technologies the project USES (detected from
   `Cargo.toml`, `*.lua`, `flake.nix`, …) are loaded eagerly at index time,
   including sources under `cheatsheet-sources/` whose license allows it.
   Measure: index size, build time on a floor-tier host, retrieval hit rate
   on a 20-question probe set, and the cost of a post-commit refresh (the
   `post-commit.lua` hook is the natural trigger; measure whether a delta
   rebuild is possible — 1259-dgaq's per-model ground-truth vectors are a
   dependency to read).
3. **Serving locally and as a fleet expert (1505-w2kq, sonnet).** Define the
   Coding Expert as a `run_grounded` domain (`coding`) so it is one more
   model id on the same endpoint (`tillandsias-experts/coding` locally,
   `tillandsias-fleet-experts/coding` over the mesh) — no second server.
   Measure the token budget of the surface + retrieved chunks per call, and
   whether a fleet call's latency over Mesh is acceptable (p50/p95 on two
   hosts). Depends on 1505-br88.
4. **Security model of the one-time signature (1505-pv3s, opus).** Threats:
   replay of a surface, widening of affordances by the model, path escape in
   `file`, the mint being asked to sign something it did not retrieve, a
   forge impersonating another project's request (the `dev-control-mcp`
   attribution hole). Outcome: a threat table with one test per row that
   the eventual implementation must pass, and a decision whether the nonce
   is HMAC-keyed (key in Vault) or a random single-use token in the server's
   memory.

## Non-goals for the research milestone

No product code; no change to `run_grounded`; no new MCP server shipped. The
packets produce measurements, prototypes under `plan/issues/` or a
`scratch/` path they name, and the follow-on implementation packets with
exit criteria that FAIL on today's tree.

## Provenance

Repository facts read at linux-next `552af2544` (symbols named above). The
operator's intent is quoted from the 2026-09-29 direction. MCP's
`tools/list_changed` notification is part of the protocol revision
`tillandsias-browser-mcp` already speaks; whether each harness honours it is
the first packet's measurement, not a claim here.

# Proposal — coding-expert-research

Umbrella packet: `1505-33dh` (milestone, desired_release v0.7, research).
Design exploration: `plan/issues/coding-expert-research-2026-09-29.md`.

## Why

The operator's direction (2026-09-29): a CODING EXPERT — an MCP server that
gives the agent harness ONE method, `write_function_for_file(contents)`,
whose signature and affordances are minted per call by the project's
embedded Lua runtime as a ONE-TIME surface; the expert is RAG-enhanced with
embeddings from the project's git mirror and from EAGERLY LOADED cheatsheets
for the project's technologies, kept fresh; served locally and as a fleet
expert.

The operator wants this researched ahead of implementation, for the
milestone after v0.6. Today the grounded pipeline answers questions with
citations or a typed refusal (`run_grounded`, spec
`expert-serve-grounded-pipeline`), but it never WRITES code, its `code`
domain embeds the working tree rather than the mirror, cheatsheets are
retrieved lazily, and no MCP surface is dynamic: every tool the harness sees
is static for the session.

## What Changes

- **ADDED** capability `coding-expert` in RESEARCH form: the requirements
  are on the research outputs (measurements with named outcomes, a threat
  table, a prototype mint script), not on product behaviour. When the
  research closes, an implementation change supersedes this one and the
  requirements are rewritten as product requirements.
- Four research packets: the dynamic one-time MCP surface minted by Lua;
  the RAG corpus from the git mirror plus eagerly loaded cheatsheets with a
  measured refresh; serving the expert as one more `run_grounded` domain
  locally and over the fleet; the security model of the one-time
  signature.

## Impact

- Specs: one new research-form capability. Nothing existing is modified.
- Code: none. Prototypes live under a path each packet names and are not
  wired into any gate.
- Dependencies: the fleet-serving packet depends on 1505-br88 (v0.6,
  `expert-serve --bind --bearer-file`); the corpus packet reads 1259-dgaq
  (per-model ground-truth vectors) before designing a delta rebuild.

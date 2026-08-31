# Local Experts Mode (grounded — order 920-pxg6)

The `local-experts` agent talks to the grounded loopback endpoint
`tillandsias-plan expert-serve` (provider `tillandsias-experts`, baseURL
`http://127.0.0.1:11436/v1`), NOT to a raw model. Every completion is one of
exactly two things:

- a **cited answer**: prose grounded in sections retrieved from the
  published content-addressed spec index, keeping ONLY the citations the
  prose actually used, validated in Rust before serving; or
- a **typed refusal**: content beginning `unsupported: ` naming what is
  missing (no built index, no embedding endpoint, no coverage in the
  requested domain).

There is no third state. The endpoint never falls back to raw model prose —
when retrieval cannot ground an answer it refuses, verbatim, as a normal
HTTP 200 completion with `finish_reason: stop`.

## The surface

- `POST /v1/chat/completions` — the model id IS the retrieval domain:
  `all`, `spec`, `code`, `methodology`, `cheatsheet`. Non-stream and
  `stream: true` (SSE terminated by `data: [DONE]`) both work.
- `GET /v1/models` — the five domain ids.
- Non-stream responses carry `rag_source_commit` (the commit the index
  entry was built at — the frame the citations mean, 801-g9nn) and
  `tillandsias_envelope` (the full ratified envelope; pipe it into
  `tillandsias-plan verify-answer` to audit the citations yourself).

Start it on a dev host with `tillandsias-plan expert-serve` (default port
11436; serves until stdin EOF). The same pipeline is available as a CLI:
`tillandsias-plan pipeline "<query>" [--domain <d>]` emits the envelope
directly. Both front-ends call ONE function — there are no divergent
grounding paths.

## Rules

- Relay refusals honestly. `unsupported: ...` means the corpus cannot
  ground the answer; do not fill the gap from model memory.
- Deterministic single-node lookups (packet status, one methodology path)
  still belong to the forge-plan MCP tools (`plan_answer`,
  `methodology_ask`, `spec_answer`).
- NEVER fabricate file paths, section names, or citations beyond what the
  endpoint returned.
- Connection refused means `expert-serve` is not running — say so and use
  the forge-plan MCP tools instead.
